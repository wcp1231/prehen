defmodule Prehen.Agent.Directive.LLMStream do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(description: "Unique call ID for correlation"),
              context: Zoi.any(description: "Conversation context"),
              candidates: Zoi.list(Zoi.map(), description: "Ordered model candidates"),
              system_prompt:
                Zoi.string(description: "Optional system prompt prepended to context")
                |> Zoi.optional(),
              tools:
                Zoi.list(Zoi.any(), description: "List of ReqLLM.Tool structs") |> Zoi.default([]),
              tool_choice:
                Zoi.any(description: "Tool choice: :auto | :none | {:required, tool_name}")
                |> Zoi.default(:auto),
              timeout:
                Zoi.integer(description: "Request timeout in milliseconds") |> Zoi.optional(),
              metadata:
                Zoi.map(description: "Arbitrary metadata for tracking") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  def schema, do: @schema

  @doc false
  def new!(attrs) when is_map(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, directive} -> directive
      {:error, errors} -> raise "Invalid Prehen LLMStream: #{inspect(errors)}"
    end
  end
end

defimpl Jido.AgentServer.DirectiveExec, for: Prehen.Agent.Directive.LLMStream do
  alias Jido.AI.{Observe, Signal, Turn}
  alias Jido.AI.Directive.Helper
  alias Jido.Tracing.Context, as: TraceContext
  alias Prehen.Agent.ModelFallback

  @impl true
  def exec(directive, _input_signal, state) do
    %{id: call_id, context: context, candidates: candidates} = directive
    metadata = Map.get(directive, :metadata, %{})
    system_prompt = Map.get(directive, :system_prompt)
    tools = Map.get(directive, :tools, [])
    tool_choice = Map.get(directive, :tool_choice, :auto)
    timeout = Map.get(directive, :timeout)
    obs_cfg = metadata[:observability] || %{}

    event_meta = %{
      agent_id: metadata[:agent_id],
      request_id: metadata[:request_id],
      run_id: metadata[:run_id] || metadata[:request_id],
      iteration: metadata[:iteration],
      llm_call_id: call_id,
      tool_call_id: nil,
      tool_name: nil,
      model: nil,
      termination_reason: nil,
      error_type: nil
    }

    agent_pid = self()
    task_supervisor = Helper.get_task_supervisor(state)

    stream_opts = %{
      call_id: call_id,
      context: context,
      system_prompt: system_prompt,
      candidates: normalize_candidates(candidates),
      tools: tools,
      tool_choice: tool_choice,
      timeout: timeout,
      agent_pid: agent_pid,
      event_meta: event_meta,
      obs_cfg: obs_cfg
    }

    parent_trace_ctx = TraceContext.get()

    case Task.Supervisor.start_child(task_supervisor, fn ->
           if parent_trace_ctx, do: Process.put({:jido, :trace_context}, parent_trace_ctx)

           started_at = System.monotonic_time(:millisecond)
           span_ctx = Observe.start_span(obs_cfg, Observe.llm(:span), event_meta)
           maybe_emit(obs_cfg, Observe.llm(:start), %{duration_ms: 0, queue_ms: 0}, event_meta)

           result =
             try do
               stream_with_fallback(stream_opts)
             rescue
               error ->
                 {:error,
                  %{
                    code: :llm_stream_exception,
                    error_type: Helper.classify_error(error),
                    reason: Exception.message(error)
                  }}
             catch
               kind, reason ->
                 {:error,
                  %{
                    code: :llm_stream_exception,
                    error_type: :unknown,
                    reason: {kind, reason}
                  }}
             end

           duration_ms = System.monotonic_time(:millisecond) - started_at

           case result do
             {:ok, _turn} ->
               Observe.finish_span(span_ctx, %{duration_ms: duration_ms})

               maybe_emit(
                 obs_cfg,
                 Observe.llm(:complete),
                 %{duration_ms: duration_ms},
                 event_meta
               )

             {:error, reason} ->
               Observe.finish_span_error(span_ctx, :error, reason, [])

               error_type =
                 case reason do
                   %{error_type: type} when is_atom(type) -> type
                   _ -> :unknown
                 end

               maybe_emit(
                 obs_cfg,
                 Observe.llm(:error),
                 %{duration_ms: duration_ms},
                 Map.put(event_meta, :error_type, error_type)
               )
           end

           signal = Signal.LLMResponse.new!(%{call_id: call_id, result: result})
           Jido.AgentServer.cast(agent_pid, signal)
         end) do
      {:ok, _pid} ->
        {:async, nil, state}

      {:error, reason} ->
        signal =
          Signal.LLMResponse.new!(%{
            call_id: call_id,
            result:
              {:error,
               %{code: :task_supervisor_error, error_type: :unknown, reason: inspect(reason)}}
          })

        Jido.AgentServer.cast(agent_pid, signal)
        {:ok, state}
    end
  end

  defp stream_with_fallback(%{
         call_id: call_id,
         context: context,
         system_prompt: system_prompt,
         candidates: candidates,
         tools: tools,
         tool_choice: tool_choice,
         timeout: timeout,
         agent_pid: agent_pid,
         event_meta: event_meta,
         obs_cfg: obs_cfg
       }) do
    messages = Helper.build_directive_messages(context, system_prompt)

    do_stream_candidates(candidates, %{
      call_id: call_id,
      messages: messages,
      tools: tools,
      tool_choice: tool_choice,
      timeout: timeout,
      agent_pid: agent_pid,
      event_meta: event_meta,
      obs_cfg: obs_cfg,
      previous_failure: nil,
      total: length(candidates)
    })
  end

  defp do_stream_candidates([], ctx) do
    reason = %{
      code: :model_fallback_exhausted,
      error_type: :provider_error,
      reason: :no_candidate_available
    }

    emit_model_event(ctx.agent_pid, %{
      kind: :exhausted,
      call_id: ctx.call_id,
      error_type: :provider_error,
      error: reason
    })

    {:error, reason}
  end

  defp do_stream_candidates([candidate | rest], ctx) do
    model = candidate.model
    metadata = %{call_id: ctx.call_id, model: model}

    if is_nil(ctx.previous_failure) do
      emit_model_event(ctx.agent_pid, %{kind: :selected, model: model, call_id: ctx.call_id})
    else
      emit_model_event(ctx.agent_pid, %{
        kind: :fallback,
        call_id: ctx.call_id,
        from_model: ctx.previous_failure.model,
        to_model: model,
        error_type: ctx.previous_failure.error_type,
        error: ctx.previous_failure.reason
      })
    end

    case stream_candidate(candidate, ctx) do
      {:ok, turn} ->
        {:ok, turn}

      {:error, reason, error_type} ->
        next_candidate = List.first(rest)

        if should_fallback?(next_candidate, error_type) do
          do_stream_candidates(rest, %{
            ctx
            | previous_failure: %{model: model, reason: reason, error_type: error_type}
          })
        else
          exhausted? = rest == [] and ctx.total > 1

          normalized_reason = %{
            code: if(exhausted?, do: :model_fallback_exhausted, else: :provider_error),
            error_type: error_type,
            model: model,
            reason: reason
          }

          if exhausted? do
            emit_model_event(ctx.agent_pid, %{
              kind: :exhausted,
              call_id: ctx.call_id,
              model: model,
              error_type: error_type,
              error: normalized_reason
            })
          end

          maybe_emit(
            ctx.obs_cfg,
            Observe.llm(:error),
            %{duration_ms: 0},
            Map.merge(ctx.event_meta, Map.merge(metadata, %{error_type: error_type}))
          )

          {:error, normalized_reason}
        end
    end
  end

  defp stream_candidate(candidate, ctx) do
    opts =
      []
      |> Helper.add_tools_opt(ctx.tools)
      |> Keyword.put(:tool_choice, ctx.tool_choice)
      |> put_model_params(candidate.params)
      |> Helper.add_timeout_opt(ctx.timeout)
      |> merge_request_opts(candidate.request_opts)

    case ReqLLM.stream_text(candidate.model, ctx.messages, opts) do
      {:ok, stream_response} ->
        on_content = fn text ->
          partial_signal =
            Signal.LLMDelta.new!(%{
              call_id: ctx.call_id,
              delta: text,
              chunk_type: :content
            })

          Jido.AgentServer.cast(ctx.agent_pid, partial_signal)
          maybe_emit_delta(ctx.obs_cfg, Observe.llm(:delta), %{duration_ms: 0}, ctx.event_meta)
        end

        on_thinking = fn text ->
          partial_signal =
            Signal.LLMDelta.new!(%{
              call_id: ctx.call_id,
              delta: text,
              chunk_type: :thinking
            })

          Jido.AgentServer.cast(ctx.agent_pid, partial_signal)
          maybe_emit_delta(ctx.obs_cfg, Observe.llm(:delta), %{duration_ms: 0}, ctx.event_meta)
        end

        case ReqLLM.StreamResponse.process_stream(stream_response,
               on_result: on_content,
               on_thinking: on_thinking
             ) do
          {:ok, response} ->
            turn = Turn.from_response(response, model: candidate.model)
            emit_usage_report(ctx.agent_pid, ctx.call_id, candidate.model, turn.usage)
            {:ok, turn}

          {:error, reason} ->
            {:error, reason, Helper.classify_error(reason)}
        end

      {:error, reason} ->
        {:error, reason, Helper.classify_error(reason)}
    end
  end

  defp should_fallback?(next_candidate, error_type),
    do: ModelFallback.should_fallback?(next_candidate, error_type)

  defp normalize_candidates(candidates) when is_list(candidates) and candidates != [] do
    Enum.map(candidates, &normalize_candidate/1)
  end

  defp normalize_candidates(_), do: [default_candidate()]

  defp normalize_candidate(%{} = candidate) do
    %{
      provider_ref: map_get(candidate, :provider_ref, "__runtime__"),
      provider: map_get(candidate, :provider, "openai"),
      model_id:
        map_get(
          candidate,
          :model_id,
          model_id_from_spec(map_get(candidate, :model, "openai:gpt-5-mini"))
        ),
      model_name:
        map_get(
          candidate,
          :model_name,
          model_id_from_spec(map_get(candidate, :model, "openai:gpt-5-mini"))
        ),
      model: normalize_model_spec(map_get(candidate, :model, "openai:gpt-5-mini")),
      params: normalize_params(map_get(candidate, :params, %{})),
      request_opts: normalize_request_opts(map_get(candidate, :request_opts, [])),
      on_errors: ModelFallback.normalize_on_errors(map_get(candidate, :on_errors, []))
    }
  end

  defp normalize_candidate(_), do: default_candidate()

  defp default_candidate do
    %{
      provider_ref: "__runtime__",
      provider: "openai",
      model_id: "gpt-5-mini",
      model_name: "gpt-5-mini",
      model: "openai:gpt-5-mini",
      params: %{temperature: 0.2, max_tokens: 1024},
      request_opts: [],
      on_errors: []
    }
  end

  defp normalize_model_spec(model) when is_binary(model) do
    normalized = String.trim(model)

    cond do
      normalized == "" -> "openai:gpt-5-mini"
      String.contains?(normalized, ":") -> normalized
      true -> "openai:#{normalized}"
    end
  end

  defp normalize_model_spec(_), do: "openai:gpt-5-mini"

  defp normalize_params(%{} = params) do
    Enum.reduce(params, %{}, fn {key, value}, acc ->
      normalized_key = key |> to_string() |> String.trim() |> String.downcase()

      case {normalized_key, value} do
        {"temperature", val} when is_integer(val) ->
          Map.put(acc, :temperature, val * 1.0)

        {"temperature", val} when is_float(val) ->
          Map.put(acc, :temperature, val)

        {"temperature", val} when is_binary(val) ->
          case Float.parse(String.trim(val)) do
            {parsed, ""} -> Map.put(acc, :temperature, parsed)
            _ -> acc
          end

        {"max_tokens", val} when is_integer(val) ->
          Map.put(acc, :max_tokens, val)

        {"max_tokens", val} when is_binary(val) ->
          case Integer.parse(String.trim(val)) do
            {parsed, ""} -> Map.put(acc, :max_tokens, parsed)
            _ -> acc
          end

        {other, val} ->
          Map.put(acc, to_atom_key(other), val)
      end
    end)
  end

  defp normalize_params(_), do: %{}

  defp put_model_params(opts, params) do
    Enum.reduce(params, opts, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc ->
        Keyword.put(acc, key, value)
    end)
  end

  defp normalize_request_opts(opts) when is_list(opts) do
    opts
    |> Enum.reduce([], fn
      {key, value}, acc when key in [:api_key, :base_url] ->
        put_if_present(acc, key, value)

      {"api_key", value}, acc ->
        put_if_present(acc, :api_key, value)

      {"base_url", value}, acc ->
        put_if_present(acc, :base_url, value)

      {:provider_options, value}, acc ->
        Keyword.put(acc, :provider_options, normalize_provider_options(value))

      {"provider_options", value}, acc ->
        Keyword.put(acc, :provider_options, normalize_provider_options(value))

      _entry, acc ->
        acc
    end)
  end

  defp normalize_request_opts(%{} = opts) do
    []
    |> put_if_present(:api_key, map_get(opts, :api_key))
    |> put_if_present(:base_url, map_get(opts, :base_url))
    |> case do
      acc ->
        provider_options = map_get(opts, :provider_options)

        if is_nil(provider_options) do
          acc
        else
          Keyword.put(acc, :provider_options, normalize_provider_options(provider_options))
        end
    end
  end

  defp normalize_request_opts(_), do: []

  defp normalize_provider_options(value) when is_list(value) do
    Enum.filter(value, &match?({_, _}, &1))
  end

  defp normalize_provider_options(%{} = value) do
    Enum.map(value, fn {key, val} ->
      {to_atom_key(key), val}
    end)
  end

  defp normalize_provider_options(_), do: []

  defp merge_request_opts(opts, request_opts) do
    normalized = normalize_request_opts(request_opts)

    Enum.reduce(normalized, opts, fn
      {:provider_options, provider_options}, acc ->
        Keyword.put(acc, :provider_options, provider_options)

      {key, value}, acc ->
        Keyword.put(acc, key, value)
    end)
  end

  defp emit_model_event(agent_pid, payload) do
    signal = Jido.Signal.new!("ai.model.event", payload, source: "/ai/model")
    Jido.AgentServer.cast(agent_pid, signal)
  end

  defp emit_usage_report(_agent_pid, _call_id, _model, nil), do: :ok

  defp emit_usage_report(agent_pid, call_id, model, usage) when is_map(usage) do
    input_tokens = Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0
    output_tokens = Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0

    if input_tokens > 0 or output_tokens > 0 do
      signal =
        Signal.Usage.new!(%{
          call_id: call_id,
          model: model,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          total_tokens: input_tokens + output_tokens,
          metadata: %{
            cache_creation_input_tokens: Map.get(usage, :cache_creation_input_tokens),
            cache_read_input_tokens: Map.get(usage, :cache_read_input_tokens)
          }
        })

      Jido.AgentServer.cast(agent_pid, signal)
    end

    :ok
  end

  defp maybe_emit(obs_cfg, event, measurements, metadata) do
    Observe.emit(obs_cfg, event, measurements, metadata)
  end

  defp maybe_emit_delta(obs_cfg, event, measurements, metadata) do
    Observe.emit(obs_cfg, event, measurements, metadata, feature_gate: :llm_deltas)
  end

  defp put_if_present(list, _key, nil), do: list

  defp put_if_present(list, _key, value) when is_binary(value) and value == "",
    do: list

  defp put_if_present(list, key, value), do: Keyword.put(list, key, value)

  defp map_get(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp map_get(map, key, default) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  defp to_atom_key(key) when is_atom(key), do: key

  defp to_atom_key(key) when is_binary(key) do
    normalized = String.trim(key)

    try do
      String.to_existing_atom(normalized)
    rescue
      ArgumentError -> String.to_atom(normalized)
    end
  end

  defp to_atom_key(key), do: key |> to_string() |> to_atom_key()

  defp model_id_from_spec(model_spec) when is_binary(model_spec) do
    case String.split(normalize_model_spec(model_spec), ":", parts: 2) do
      [_provider, model_id] when model_id != "" -> model_id
      _ -> "gpt-5-mini"
    end
  end

  defp model_id_from_spec(_), do: "gpt-5-mini"
end
