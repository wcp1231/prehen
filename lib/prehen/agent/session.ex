defmodule Prehen.Agent.Session do
  @moduledoc """
  会话执行面（data plane）进程。

  中文：
  - 负责同一 `session` 内请求队列与回合调度（`prompt/steering/follow_up`）。
  - 统一处理中断语义：`steering` 会优先抢占并取消当前回合。
  - 产出 typed events，并同步写入 canonical conversation/event store。
  - 在每回合结束时更新 memory（STM 主，LTM 可降级）。

  English:
  - Data-plane process for single-session execution.
  - Owns queueing and turn scheduling for `prompt/steering/follow_up`.
  - Centralizes interruption semantics (`steering` preempts in-flight turns).
  - Emits typed events and persists them to the canonical conversation/event store.
  - Updates memory at turn boundaries (STM-first, LTM can degrade safely).
  """

  use GenServer

  alias Prehen.Agent.EventBridge
  alias Prehen.Agent.Policies.{ModelRouter, RetryPolicy}
  alias Prehen.Memory
  alias Prehen.Workspace.{Paths, SessionQueue}

  @type queue_kind :: SessionQueue.queue_kind()

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

  @doc """
  提交普通用户消息到会话队列（低于 steering 优先级）。
  Enqueue a normal user prompt for the current session.
  """
  @spec prompt(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def prompt(server, text, opts \\ []) when is_binary(text) do
    enqueue(server, :prompt, text, opts)
  end

  @doc """
  提交 steering 消息，触发抢占语义并优先执行。
  Enqueue a steering message with preemption priority.
  """
  @spec steer(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def steer(server, text, opts \\ []) when is_binary(text) do
    enqueue(server, :steering, text, opts)
  end

  @doc """
  提交 follow-up 消息，当前回合完成后续接执行。
  Enqueue a follow-up message to continue after current turn.
  """
  @spec follow_up(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def follow_up(server, text, opts \\ []) when is_binary(text) do
    enqueue(server, :follow_up, text, opts)
  end

  @doc """
  阻塞等待会话空闲，并返回统一结果（含 trace）。
  Block until the session becomes idle and return the final runtime result.
  """
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
    session_id = resolve_session_id(config)
    turn_seq = normalize_non_neg_int(Map.get(config, :turn_seq), 0)

    with {:ok, agent} <- adapter.start_agent(config) do
      state = %{
        config: config,
        adapter: adapter,
        agent: agent,
        session_id: session_id,
        status: :idle,
        queue: SessionQueue.new(),
        active: nil,
        waiters: [],
        events: [],
        turn_seq: turn_seq,
        queue_drained_emitted?: false,
        last_result: nil
      }

      case maybe_restore_from_ledger(state) do
        {:ok, restored_state} ->
          restored_state =
            restored_state
            |> maybe_init_memory_session()
            |> maybe_emit_queue_drained()

          {:ok, restored_state}

        {:error, reason} ->
          {:stop, reason}
      end
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
    queue_sizes = SessionQueue.sizes(state.queue)

    snapshot = %{
      session_id: state.session_id,
      status: state.status,
      active: summarize_active(state.active),
      queue_sizes: queue_sizes
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
    |> Map.put_new(:workspace_dir, Paths.resolve_workspace_dir())
    |> Map.put_new(:stm_buffer_limit, 24)
    |> Map.put_new(:stm_token_budget, 8_000)
    |> Map.put_new(:ltm_adapter_name, :noop)
    |> Map.put_new(:ltm_adapter, nil)
    |> Map.put_new(:capability_packs, [:local_fs])
    |> Map.put_new(:workspace_capability_allowlist, [:local_fs])
    |> Map.put_new(:tools, [Prehen.Actions.LS, Prehen.Actions.Read])
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
    # Steering preempts the in-flight turn but leaves queued items intact.
    # Steering 会抢占当前回合，但不会清空队列中的后续消息。
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
    case SessionQueue.pop_next(state.queue) do
      {:none, _queue} ->
        maybe_emit_queue_drained(state)

      {item, next_queue} ->
        start_turn(%{state | queue: next_queue}, item)
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
          model_event_count: 0,
          model_exhausted?: false,
          model_error: nil,
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
        |> store_message(%{
          role: :user,
          content: item.text,
          request_id: request_id,
          run_id: run_id,
          turn_id: turn_id
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
        |> ingest_model_events(details)

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
    working_context = %{last_turn_status: :ok, last_answer: answer}

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
    |> emit_turn_summary(%{
      input: state.active.item.text,
      answer: answer,
      status: :ok,
      tool_calls: summarize_tool_states(state.active.tool_states),
      working_context: working_context
    })
    |> store_message(%{
      role: :assistant,
      content: answer,
      request_id: state.active.request_id,
      run_id: state.active.run_id,
      turn_id: state.active.turn_id
    })
    |> Map.put(:last_result, %{status: :ok, reason: nil, answer: answer})
    |> persist_memory_turn(%{
      status: :ok,
      answer: answer,
      raw_result: result,
      working_context: working_context
    })
    |> clear_active()
  end

  defp finalize_turn(state, {:error, reason}) do
    normalized_reason = normalize_failure_reason(state, reason)
    partial = get_in(state, [:active, :partial_message]) || ""
    working_context = %{last_turn_status: :error, last_error: inspect(normalized_reason)}

    state =
      state
      |> maybe_emit_aborted_response(partial, normalized_reason)
      |> maybe_emit_skipped_tool_results()
      |> emit("ai.request.failed", %{
        request_id: state.active.request_id,
        run_id: state.active.run_id,
        turn_id: state.active.turn_id,
        error: normalized_reason
      })
      |> emit("ai.session.turn.completed", %{
        request_id: state.active.request_id,
        run_id: state.active.run_id,
        turn_id: state.active.turn_id,
        outcome: :failed,
        reason: normalized_reason
      })
      |> emit_turn_summary(%{
        input: state.active.item.text,
        answer: partial,
        status: :error,
        tool_calls: summarize_tool_states(state.active.tool_states),
        working_context: working_context
      })
      |> store_message(%{
        role: :assistant,
        content: partial,
        status: :failed,
        reason: normalized_reason,
        request_id: state.active.request_id,
        run_id: state.active.run_id,
        turn_id: state.active.turn_id
      })
      |> Map.put(:last_result, %{
        status: :error,
        reason: normalized_reason,
        answer: "执行失败：#{inspect(normalized_reason)}"
      })
      |> persist_memory_turn(%{
        status: :error,
        reason: normalized_reason,
        answer: partial,
        working_context: working_context
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

  defp emit_turn_summary(state, payload) when is_map(payload) do
    emit(state, "ai.session.turn.summary", payload)
  end

  defp maybe_emit_skipped_tool_results(%{active: %{interrupted?: true} = active} = state) do
    # Any unresolved tool call is materialized as "skipped" so downstream
    # consumers get a consistent, side-effect-free interruption trace.
    # 中断时把未完成工具调用显式落为 skipped，确保下游可一致消费且无副作用。
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

  defp ingest_model_events(%{active: nil} = state, _details), do: state

  defp ingest_model_events(%{active: active} = state, details) do
    events = map_get(details, :model_events, [])

    cond do
      not is_list(events) ->
        state

      true ->
        known_count = active.model_event_count || 0
        new_events = Enum.drop(events, known_count)

        state =
          Enum.reduce(new_events, state, fn event, acc ->
            emit_model_event(acc, event)
          end)

        next_state = put_in(state, [:active, :model_event_count], length(events))

        if Enum.any?(new_events, fn event -> map_get(event, :kind) == :exhausted end) do
          next_state
          |> put_in([:active, :model_exhausted?], true)
          |> put_in([:active, :model_error], List.last(new_events))
        else
          next_state
        end
    end
  end

  defp emit_model_event(state, event) when is_map(event) do
    kind = map_get(event, :kind)

    case kind do
      :selected ->
        emit(state, "ai.model.selected", %{
          call_id: map_get(event, :call_id),
          model: map_get(event, :model)
        })

      :fallback ->
        emit(state, "ai.model.fallback", %{
          call_id: map_get(event, :call_id),
          from_model: map_get(event, :from_model),
          to_model: map_get(event, :to_model),
          error_type: map_get(event, :error_type),
          error: map_get(event, :error)
        })

      :exhausted ->
        emit(state, "ai.model.exhausted", %{
          call_id: map_get(event, :call_id),
          model: map_get(event, :model),
          error_type: map_get(event, :error_type),
          error: map_get(event, :error)
        })

      _ ->
        state
    end
  end

  defp emit_model_event(state, _event), do: state

  defp normalize_failure_reason(%{active: %{model_exhausted?: true}} = state, reason) do
    if match?({:model_fallback_exhausted, _}, reason) do
      reason
    else
      {:model_fallback_exhausted,
       %{reason: reason, model_error: get_in(state, [:active, :model_error])}}
    end
  end

  defp normalize_failure_reason(_state, reason), do: reason

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
    trace = canonical_trace(state.session_id, state.events)

    base =
      state.last_result ||
        %{
          status: :ok,
          reason: nil,
          answer: ""
        }

    Map.merge(base, %{
      steps: count_steps(trace),
      trace: trace
    })
  end

  defp count_steps(events) do
    Enum.count(events, fn event -> event.type == "ai.react.step" end)
  end

  defp emit(state, type, payload) do
    correlation = correlation_fields(state)
    event = EventBridge.project(type, Map.merge(correlation, payload))

    case Prehen.Conversation.Store.write(state.session_id, Map.put(event, :kind, :event)) do
      {:ok, _record} -> %{state | events: state.events ++ [event]}
      {:error, _reason} -> state
    end
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

  defp put_queue_item(state, kind, item),
    do: %{state | queue: SessionQueue.put(state.queue, kind, item)}

  defp idle?(state) do
    is_nil(state.active) and SessionQueue.empty?(state.queue)
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
      workspace_dir: config[:workspace_dir],
      read_max_bytes: config[:read_max_bytes]
    }
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp map_get(_, _key, default), do: default

  defp resolve_session_id(config) do
    case Map.get(config, :session_id) do
      session_id when is_binary(session_id) and session_id != "" -> session_id
      _ -> gen_id("session")
    end
  end

  defp normalize_non_neg_int(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_int(_value, fallback), do: fallback

  defp gen_id(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp canonical_trace(session_id, _fallback) do
    case Prehen.Conversation.Store.replay_result(session_id, kind: :event) do
      {:ok, records} ->
        Enum.map(records, fn record ->
          Map.drop(record, [:kind, :stored_at_ms])
        end)

      {:error, _reason} ->
        []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp maybe_restore_from_ledger(state) do
    if resume_requested?(state.config) do
      if Prehen.Conversation.SessionLedger.session_exists?(state.session_id) do
        case Prehen.Conversation.Store.replay_result(state.session_id) do
          {:ok, records} ->
            with {:ok, _projection} <-
                   Memory.rebuild_session(state.session_id, records, memory_opts(state.config)) do
              turn_seq = max(state.turn_seq, max_turn_seq(records))

              recovered_state =
                state
                |> Map.put(:turn_seq, turn_seq)
                |> emit("ai.session.recovered", %{
                  turn_seq: turn_seq,
                  replayed_records: length(records)
                })

              {:ok, recovered_state}
            else
              {:error, reason} ->
                {:error, {:session_recovery_failed, state.session_id, reason}}
            end

          {:error, reason} ->
            {:error, {:session_recovery_failed, state.session_id, reason}}
        end
      else
        {:error, {:session_recovery_failed, state.session_id, :ledger_not_found}}
      end
    else
      {:ok, state}
    end
  end

  defp resume_requested?(config) do
    Map.get(config, :resume, false) == true
  end

  defp max_turn_seq(records) do
    Enum.reduce(records, 0, fn record, acc ->
      turn_id = map_get(record, :turn_id)

      if is_integer(turn_id) and turn_id > acc do
        turn_id
      else
        acc
      end
    end)
  end

  defp maybe_init_memory_session(state) do
    _ = Memory.ensure_session(state.session_id, memory_opts(state.config))
    state
  end

  defp persist_memory_turn(%{active: nil} = state, _payload), do: state

  defp persist_memory_turn(state, payload) do
    turn =
      %{
        source: "session",
        request_id: state.active.request_id,
        run_id: state.active.run_id,
        turn_id: state.active.turn_id,
        kind: state.active.item.kind,
        input: state.active.item.text,
        tool_calls: summarize_tool_states(state.active.tool_states),
        at_ms: System.system_time(:millisecond)
      }
      |> Map.merge(payload)

    _ = Memory.record_turn(state.session_id, turn, memory_opts(state.config))
    state
  end

  defp store_message(state, message) when is_map(message) do
    record =
      message
      |> Map.put_new(:kind, :message)
      |> Map.put_new(:session_id, state.session_id)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Prehen.Conversation.Store.write(state.session_id, record) do
      {:ok, _record} -> state
      {:error, _reason} -> state
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  defp summarize_tool_states(tool_states) when is_map(tool_states) do
    Enum.map(tool_states, fn {call_id, info} ->
      %{
        call_id: call_id,
        name: info.name,
        status: info.status,
        result: info.result
      }
    end)
  end

  defp summarize_tool_states(_), do: []

  defp memory_opts(config) do
    [
      buffer_limit: config[:stm_buffer_limit],
      token_budget_limit: config[:stm_token_budget],
      ltm_adapter: config[:ltm_adapter],
      ltm_adapter_name: config[:ltm_adapter_name]
    ]
  end
end
