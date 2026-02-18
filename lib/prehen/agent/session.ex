defmodule Prehen.Agent.Session do
  @moduledoc false

  use GenServer

  alias Prehen.Agent.EventBridge
  alias Prehen.Agent.Policies.{ModelRouter, RetryPolicy}

  @type queue_kind :: :prompt | :steering | :follow_up

  @spec start(map(), keyword()) :: GenServer.on_start()
  def start(config, opts \\ []) when is_map(config) do
    GenServer.start(__MODULE__, config, opts)
  end

  @spec start_link(map(), keyword()) :: GenServer.on_start()
  def start_link(config, opts \\ []) when is_map(config) do
    GenServer.start_link(__MODULE__, config, opts)
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal, 5_000)
  end

  @spec prompt(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def prompt(server, text, opts \\ []) when is_binary(text) do
    enqueue(server, :prompt, text, opts)
  end

  @spec steer(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def steer(server, text, opts \\ []) when is_binary(text) do
    enqueue(server, :steering, text, opts)
  end

  @spec follow_up(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def follow_up(server, text, opts \\ []) when is_binary(text) do
    enqueue(server, :follow_up, text, opts)
  end

  @spec await_idle(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_idle(server, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(server, :await_idle, timeout)
  end

  @spec events(GenServer.server()) :: [map()]
  def events(server) do
    GenServer.call(server, :events)
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(config) do
    config =
      config
      |> ensure_defaults()
      |> apply_model_router()

    adapter = config[:session_adapter]

    with {:ok, agent} <- adapter.start_agent(config) do
      state = %{
        config: config,
        adapter: adapter,
        agent: agent,
        session_id: gen_id("session"),
        status: :idle,
        prompt_q: :queue.new(),
        steer_q: :queue.new(),
        followup_q: :queue.new(),
        active: nil,
        waiters: [],
        events: [],
        turn_seq: 0,
        queue_drained_emitted?: false,
        last_result: nil
      }

      {:ok, maybe_emit_queue_drained(state)}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:enqueue, kind, text, opts}, _from, state)
      when kind in [:prompt, :steering, :follow_up] do
    if String.trim(text) == "" do
      {:reply, {:error, %{type: :validation_error, message: "empty message"}}, state}
    else
      item = %{
        kind: kind,
        text: text,
        run_id: Keyword.get(opts, :run_id, gen_id("run")),
        opts: opts
      }

      state =
        state
        |> put_queue_item(kind, item)
        |> Map.put(:queue_drained_emitted?, false)
        |> maybe_cancel_for_steering(kind)
        |> maybe_start_next_turn()

      {:reply, {:ok, %{queued: true, kind: kind, session_id: state.session_id}}, state}
    end
  end

  def handle_call(:await_idle, from, state) do
    if idle?(state) do
      {:reply, {:ok, build_runtime_result(state)}, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call(:events, _from, state), do: {:reply, state.events, state}

  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      session_id: state.session_id,
      status: state.status,
      active: summarize_active(state.active),
      queue_sizes: %{
        prompt: :queue.len(state.prompt_q),
        steering: :queue.len(state.steer_q),
        follow_up: :queue.len(state.followup_q)
      }
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info(:status_tick, %{active: nil} = state), do: {:noreply, state}

  def handle_info(:status_tick, state) do
    state =
      state
      |> update_from_status()
      |> schedule_tick()

    {:noreply, state}
  end

  def handle_info(
        {:await_result, request_id, result},
        %{active: %{request_id: request_id}} = state
      ) do
    state =
      state
      |> update_from_status()
      |> finalize_turn(result)
      |> maybe_start_next_turn()
      |> maybe_reply_waiters()

    {:noreply, state}
  end

  def handle_info({:await_result, _request_id, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active: %{await_ref: ref}} = state) do
    state =
      if reason in [:normal, :shutdown] do
        state
      else
        state
        |> finalize_turn({:error, {:await_crash, reason}})
        |> maybe_start_next_turn()
        |> maybe_reply_waiters()
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = state.adapter.stop_agent(state.agent)
    :ok
  end

  defp enqueue(server, kind, text, opts) do
    GenServer.call(server, {:enqueue, kind, text, opts})
  end

  defp ensure_defaults(config) do
    config
    |> Map.put_new(:session_adapter, Prehen.Agent.Session.Adapters.JidoAI)
    |> Map.put_new(:retry_policy, RetryPolicy)
    |> Map.put_new(:model_router, ModelRouter)
    |> Map.put_new(:session_status_poll_ms, 50)
    |> Map.put_new(:timeout_ms, 15_000)
    |> Map.put_new(:max_steps, 8)
  end

  defp apply_model_router(config) do
    router = config[:model_router]
    model = router.select(config, %{event: :session_init})
    Map.put(config, :model, model)
  rescue
    _ -> config
  end

  defp maybe_cancel_for_steering(%{active: nil} = state, _kind), do: state
  defp maybe_cancel_for_steering(state, kind) when kind != :steering, do: state

  defp maybe_cancel_for_steering(%{active: active} = state, :steering) do
    _ = state.adapter.steer(state.agent, request_id: active.request_id, reason: :steering)

    emit(state, "ai.session.steer", %{
      request_id: active.request_id,
      run_id: active.run_id,
      turn_id: active.turn_id,
      reason: :steering
    })
    |> put_in([:active, :interrupted?], true)
  end

  defp maybe_start_next_turn(%{active: active} = state) when not is_nil(active), do: state

  defp maybe_start_next_turn(state) do
    case pop_next_item(state) do
      {:none, state} ->
        maybe_emit_queue_drained(state)

      {item, state} ->
        start_turn(state, item)
    end
  end

  defp start_turn(state, item) do
    request_id = Keyword.get(item.opts, :request_id, gen_id("request"))
    run_id = item.run_id || request_id
    turn_id = state.turn_seq + 1

    ask_opts =
      item.opts
      |> Keyword.drop([:run_id, :request_id])
      |> Keyword.put(:request_id, request_id)
      |> Keyword.put_new(:tool_context, tool_context(state.config))

    retry_policy = state.config[:retry_policy]

    ask_result =
      retry_policy.run(
        fn -> state.adapter.ask(state.agent, item.text, ask_opts) end,
        attempts: 1,
        backoff_ms: 0
      )

    case ask_result do
      {:ok, request} ->
        parent = self()

        {await_pid, await_ref} =
          spawn_monitor(fn ->
            result = state.adapter.await(state.agent, request, timeout: state.config[:timeout_ms])
            send(parent, {:await_result, request_id, result})
          end)

        active = %{
          request_id: request_id,
          run_id: run_id,
          turn_id: turn_id,
          item: item,
          request: request,
          await_pid: await_pid,
          await_ref: await_ref,
          interrupted?: false,
          llm_call_id: nil,
          stream_len: 0,
          partial_message: "",
          thinking_count: 0,
          tool_states: %{},
          skipped_emitted?: false
        }

        state
        |> Map.put(:status, :running)
        |> Map.put(:turn_seq, turn_id)
        |> Map.put(:active, active)
        |> emit("ai.session.turn.started", %{
          request_id: request_id,
          run_id: run_id,
          turn_id: turn_id,
          message_kind: item.kind
        })
        |> emit("ai.request.started", %{
          request_id: request_id,
          run_id: run_id,
          turn_id: turn_id,
          query: item.text
        })
        |> schedule_tick()

      {:error, reason} ->
        state
        |> emit("ai.request.failed", %{
          error: reason,
          run_id: run_id,
          request_id: request_id,
          turn_id: turn_id
        })
        |> Map.put(:last_result, %{
          status: :error,
          reason: reason,
          answer: "执行失败：#{inspect(reason)}"
        })
        |> Map.put(:status, :idle)
    end
  end

  defp schedule_tick(%{active: nil} = state), do: state

  defp schedule_tick(state) do
    Process.send_after(self(), :status_tick, state.config[:session_status_poll_ms])
    state
  end

  defp update_from_status(%{active: nil} = state), do: state

  defp update_from_status(state) do
    case state.adapter.status(state.agent) do
      {:ok, status} ->
        details = extract_status_details(status)

        state
        |> ingest_llm_delta(details)
        |> ingest_thinking(details)
        |> ingest_tool_calls(details)

      {:error, _} ->
        state
    end
  end

  defp ingest_llm_delta(%{active: active} = state, details) do
    call_id = map_get(details, :current_llm_call_id)
    streaming_text = map_get(details, :streaming_text, "")

    cond do
      not is_binary(call_id) or call_id == "" or not is_binary(streaming_text) ->
        state

      true ->
        active =
          if active.llm_call_id != call_id do
            %{active | llm_call_id: call_id, stream_len: 0, partial_message: ""}
          else
            active
          end

        current_len = byte_size(streaming_text)

        if current_len > active.stream_len do
          delta = :binary.part(streaming_text, active.stream_len, current_len - active.stream_len)

          state
          |> emit("ai.llm.delta", %{
            call_id: call_id,
            delta: delta,
            chunk_type: :content
          })
          |> put_in([:active, :stream_len], current_len)
          |> put_in([:active, :partial_message], active.partial_message <> delta)
        else
          put_in(state, [:active], active)
        end
    end
  end

  defp ingest_thinking(%{active: active} = state, details) do
    thinking_trace = map_get(details, :thinking_trace, [])

    if is_list(thinking_trace) and length(thinking_trace) > active.thinking_count do
      new_entries = Enum.drop(thinking_trace, active.thinking_count)

      state =
        Enum.reduce(new_entries, state, fn entry, acc ->
          emit(acc, "ai.react.step", %{
            phase: :thought,
            call_id: map_get(entry, :call_id),
            content: map_get(entry, :thinking, ""),
            iteration: map_get(entry, :iteration)
          })
        end)

      put_in(state, [:active, :thinking_count], length(thinking_trace))
    else
      state
    end
  end

  defp ingest_tool_calls(state, details) do
    tool_calls = map_get(details, :tool_calls, [])

    if is_list(tool_calls) do
      Enum.reduce(tool_calls, state, fn tool_call, acc ->
        id = map_get(tool_call, :id)
        name = map_get(tool_call, :name)
        status = normalize_tool_status(map_get(tool_call, :status))
        result = map_get(tool_call, :result)

        cond do
          not is_binary(id) or id == "" ->
            acc

          true ->
            previous = get_in(acc, [:active, :tool_states, id])

            acc =
              if is_nil(previous) do
                acc
                |> emit("ai.tool.call", %{
                  call_id: id,
                  tool_name: name,
                  arguments: map_get(tool_call, :arguments, %{})
                })
                |> emit("ai.react.step", %{
                  phase: :action,
                  call_id: id,
                  tool_name: name
                })
              else
                acc
              end

            acc =
              if (is_nil(previous) or previous.status != :completed) and status == :completed do
                acc
                |> emit("ai.tool.result", %{
                  call_id: id,
                  tool_name: name,
                  result: result
                })
                |> emit("ai.react.step", %{
                  phase: :observation,
                  call_id: id,
                  tool_name: name,
                  content: summarize_result(result)
                })
              else
                acc
              end

            put_in(acc, [:active, :tool_states, id], %{status: status, name: name, result: result})
        end
      end)
    else
      state
    end
  end

  defp finalize_turn(state, {:ok, result}) do
    answer = extract_answer(result)
    call_id = get_in(state, [:active, :llm_call_id]) || get_in(state, [:active, :request_id])

    state
    |> maybe_emit_llm_response(call_id, result)
    |> emit("ai.request.completed", %{
      request_id: state.active.request_id,
      run_id: state.active.run_id,
      turn_id: state.active.turn_id,
      result: answer
    })
    |> emit("ai.react.step", %{
      phase: :final,
      call_id: call_id,
      content: answer
    })
    |> emit("ai.session.turn.completed", %{
      request_id: state.active.request_id,
      run_id: state.active.run_id,
      turn_id: state.active.turn_id,
      outcome: :completed
    })
    |> Map.put(:last_result, %{status: :ok, reason: nil, answer: answer})
    |> clear_active()
  end

  defp finalize_turn(state, {:error, reason}) do
    partial = get_in(state, [:active, :partial_message]) || ""

    state =
      state
      |> maybe_emit_aborted_response(partial, reason)
      |> maybe_emit_skipped_tool_results()
      |> emit("ai.request.failed", %{
        request_id: state.active.request_id,
        run_id: state.active.run_id,
        turn_id: state.active.turn_id,
        error: reason
      })
      |> emit("ai.session.turn.completed", %{
        request_id: state.active.request_id,
        run_id: state.active.run_id,
        turn_id: state.active.turn_id,
        outcome: :failed,
        reason: reason
      })
      |> Map.put(:last_result, %{
        status: :error,
        reason: reason,
        answer: "执行失败：#{inspect(reason)}"
      })

    clear_active(state)
  end

  defp maybe_emit_aborted_response(state, partial, reason)
       when is_binary(partial) and partial != "" do
    call_id = get_in(state, [:active, :llm_call_id]) || get_in(state, [:active, :request_id])

    state
    |> emit("ai.llm.response", %{
      call_id: call_id,
      result: {:error, reason},
      partial: partial,
      aborted: true
    })
    |> emit("ai.react.step", %{phase: :final, call_id: call_id, content: :aborted})
  end

  defp maybe_emit_aborted_response(state, _partial, _reason) do
    call_id = get_in(state, [:active, :llm_call_id]) || get_in(state, [:active, :request_id])
    emit(state, "ai.react.step", %{phase: :final, call_id: call_id, content: :aborted})
  end

  defp maybe_emit_llm_response(state, call_id, result) do
    partial = get_in(state, [:active, :partial_message]) || ""

    if is_binary(partial) and partial != "" do
      emit(state, "ai.llm.response", %{call_id: call_id, result: result, partial: partial})
    else
      emit(state, "ai.llm.response", %{call_id: call_id, result: result})
    end
  end

  defp maybe_emit_skipped_tool_results(%{active: %{interrupted?: true} = active} = state) do
    pending =
      active.tool_states
      |> Enum.filter(fn {_id, info} -> info.status != :completed end)

    Enum.reduce(pending, state, fn {call_id, info}, acc ->
      skipped = %{
        type: "skipped",
        message: "Skipped due to queued user message"
      }

      acc
      |> emit("ai.tool.result", %{
        call_id: call_id,
        tool_name: info.name,
        result: {:error, skipped}
      })
      |> emit("ai.react.step", %{
        phase: :observation,
        call_id: call_id,
        tool_name: info.name,
        content: skipped.message
      })
    end)
  end

  defp maybe_emit_skipped_tool_results(state), do: state

  defp clear_active(state) do
    state
    |> Map.put(:active, nil)
    |> Map.put(:status, :idle)
  end

  defp maybe_reply_waiters(state) do
    if idle?(state) and state.waiters != [] do
      result = {:ok, build_runtime_result(state)}
      Enum.each(state.waiters, &GenServer.reply(&1, result))
      %{state | waiters: []}
    else
      state
    end
  end

  defp build_runtime_result(state) do
    base =
      state.last_result ||
        %{
          status: :ok,
          reason: nil,
          answer: ""
        }

    Map.merge(base, %{
      steps: count_steps(state.events),
      trace: state.events
    })
  end

  defp count_steps(events) do
    Enum.count(events, fn event -> event.type == "ai.react.step" end)
  end

  defp emit(state, type, payload) do
    correlation = correlation_fields(state)
    event = EventBridge.project(type, Map.merge(correlation, payload))
    %{state | events: state.events ++ [event]}
  end

  defp correlation_fields(%{session_id: session_id, active: nil}) do
    %{session_id: session_id}
  end

  defp correlation_fields(%{session_id: session_id, active: active}) do
    %{
      session_id: session_id,
      request_id: active.request_id,
      run_id: active.run_id,
      turn_id: active.turn_id
    }
  end

  defp maybe_emit_queue_drained(state) do
    if idle?(state) and not state.queue_drained_emitted? do
      state
      |> emit("ai.session.queue.drained", %{session_id: state.session_id})
      |> Map.put(:queue_drained_emitted?, true)
      |> maybe_reply_waiters()
    else
      state
    end
  end

  defp pop_next_item(state) do
    cond do
      not :queue.is_empty(state.steer_q) ->
        {{:value, item}, q} = :queue.out(state.steer_q)
        {item, %{state | steer_q: q}}

      not :queue.is_empty(state.prompt_q) ->
        {{:value, item}, q} = :queue.out(state.prompt_q)
        {item, %{state | prompt_q: q}}

      not :queue.is_empty(state.followup_q) ->
        {{:value, item}, q} = :queue.out(state.followup_q)
        {item, %{state | followup_q: q}}

      true ->
        {:none, state}
    end
  end

  defp put_queue_item(state, :prompt, item),
    do: %{state | prompt_q: :queue.in(item, state.prompt_q)}

  defp put_queue_item(state, :steering, item),
    do: %{state | steer_q: :queue.in(item, state.steer_q)}

  defp put_queue_item(state, :follow_up, item),
    do: %{state | followup_q: :queue.in(item, state.followup_q)}

  defp idle?(state) do
    is_nil(state.active) and :queue.is_empty(state.prompt_q) and :queue.is_empty(state.steer_q) and
      :queue.is_empty(state.followup_q)
  end

  defp extract_status_details(%{snapshot: snapshot}) when is_map(snapshot) do
    Map.get(snapshot, :details, Map.get(snapshot, "details", %{}))
  end

  defp extract_status_details(status) do
    if function_exported?(Jido.AgentServer.Status, :details, 1) do
      try do
        Jido.AgentServer.Status.details(status)
      rescue
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp normalize_tool_status(nil), do: :unknown
  defp normalize_tool_status(value) when is_atom(value), do: value

  defp normalize_tool_status(value) when is_binary(value) do
    case value do
      "completed" -> :completed
      "running" -> :running
      "pending" -> :pending
      _ -> :unknown
    end
  end

  defp normalize_tool_status(_), do: :unknown

  defp extract_answer(answer) when is_binary(answer), do: answer
  defp extract_answer(%{text: text}) when is_binary(text), do: text
  defp extract_answer(answer), do: inspect(answer)

  defp summarize_active(nil), do: nil

  defp summarize_active(active) do
    %{
      request_id: active.request_id,
      run_id: active.run_id,
      turn_id: active.turn_id,
      interrupted?: active.interrupted?,
      kind: active.item.kind
    }
  end

  defp summarize_result({:ok, value}), do: "ok: #{inspect(value)}"
  defp summarize_result({:error, reason}), do: "error: #{inspect(reason)}"
  defp summarize_result(value), do: inspect(value)

  defp tool_context(config) do
    %{
      root_dir: config[:root_dir],
      read_max_bytes: config[:read_max_bytes]
    }
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp map_get(_, _key, default), do: default

  defp gen_id(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end
end
