defmodule Prehen.Agent.Strategies.ReactExt do
  @moduledoc false

  use Jido.Agent.Strategy

  alias Jido.Agent
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.AI.Directive.LLMStream, as: JidoLLMStream
  alias Jido.AI.Strategies.ReAct
  alias Prehen.Agent.Directive.LLMStream, as: PrehenLLMStream
  alias Prehen.Agent.Strategies.ReactMachineExt

  @followup :prehen_react_followup
  @steer :prehen_react_steer
  @model_event :prehen_model_event

  @impl true
  def action_spec(@followup) do
    %{
      schema:
        Zoi.object(%{
          query: Zoi.string(),
          request_id: Zoi.string() |> Zoi.optional()
        }),
      doc: "Queue a follow-up query in the current session",
      name: "ai.session.follow_up"
    }
  end

  def action_spec(@steer) do
    %{
      schema:
        Zoi.object(%{
          reason: Zoi.atom() |> Zoi.default(:steering),
          request_id: Zoi.string() |> Zoi.optional()
        }),
      doc: "Interrupt current run and steer to next queued user message",
      name: "ai.session.steer"
    }
  end

  def action_spec(@model_event) do
    %{
      schema:
        Zoi.object(%{
          kind: Zoi.atom(),
          call_id: Zoi.string() |> Zoi.optional(),
          model: Zoi.string() |> Zoi.optional(),
          from_model: Zoi.string() |> Zoi.optional(),
          to_model: Zoi.string() |> Zoi.optional(),
          error_type: Zoi.atom() |> Zoi.optional(),
          error: Zoi.any() |> Zoi.optional()
        }),
      doc: "Model selection/fallback lifecycle event",
      name: "ai.model.event"
    }
  end

  def action_spec(action), do: ReAct.action_spec(action)

  @impl true
  def signal_routes(ctx) do
    ReAct.signal_routes(ctx) ++
      [
        {"ai.session.steer", {:strategy_cmd, @steer}},
        {"ai.session.follow_up", {:strategy_cmd, @followup}},
        {"ai.model.event", {:strategy_cmd, @model_event}}
      ]
  end

  @impl true
  def snapshot(%Agent{} = agent, ctx) do
    snapshot = ReAct.snapshot(agent, ctx)
    state = agent |> StratState.get(%{}) |> ReactMachineExt.ensure()

    details =
      snapshot.details
      |> Map.put(:turn_phase, state[:turn_phase])
      |> Map.put(:prompt_q, length(state[:prompt_q] || []))
      |> Map.put(:steer_q, length(state[:steer_q] || []))
      |> Map.put(:followup_q, length(state[:followup_q] || []))
      |> Map.put(:pending_tool_calls, state[:pending_tool_calls] || [])
      |> Map.put(:model_events, state[:model_events] || [])
      |> Map.put(:model_error, state[:model_error])

    %{snapshot | details: details}
  end

  @impl true
  def init(%Agent{} = agent, ctx) do
    {agent, directives} = ReAct.init(agent, ctx)

    {put_ext_state(agent, %{
       llm_runtime: extract_llm_runtime(ctx),
       model_events: [],
       model_error: nil
     }), directives}
  end

  @impl true
  def cmd(%Agent{} = agent, instructions, ctx) do
    state = agent |> StratState.get(%{}) |> ReactMachineExt.ensure() |> ensure_ext_state(ctx)
    {state, rewritten} = rewrite_instructions(state, instructions)
    agent = StratState.put(agent, state)

    {agent, directives} = ReAct.cmd(agent, rewritten, ctx)
    directives = rewrite_directives(agent, directives, state)
    agent = put_ext_state(agent, state)
    continue_queued(agent, directives, ctx, 0)
  end

  defp continue_queued(agent, directives, _ctx, depth) when depth >= 3, do: {agent, directives}

  defp continue_queued(agent, directives, ctx, depth) do
    state = agent |> StratState.get(%{}) |> ReactMachineExt.ensure()

    cond do
      ReactMachineExt.ready_for_next?(state) ->
        case ReactMachineExt.dequeue_next(state) do
          {:none, state} ->
            {StratState.put(agent, state), directives}

          {item, state} ->
            agent = StratState.put(agent, state)

            start_instruction =
              instruction(ReAct.start_action(), %{
                query: item.query,
                request_id: item.request_id
              })

            {agent, more_directives} = ReAct.cmd(agent, [start_instruction], ctx)
            agent = put_ext_state(agent, state)
            continue_queued(agent, directives ++ more_directives, ctx, depth + 1)
        end

      true ->
        {agent, directives}
    end
  end

  defp rewrite_instructions(state, instructions) do
    Enum.reduce(instructions, {state, []}, fn instruction, {acc_state, acc} ->
      action = normalize_action(instruction.action)

      case action do
        @followup ->
          params = normalize_params(instruction.params)
          query = map_get(params, :query)

          item = %{
            query: query,
            request_id: Map.get(params, :request_id, gen_request_id())
          }

          if is_binary(query) and query != "" do
            {ReactMachineExt.enqueue(acc_state, :followup, item), acc}
          else
            {acc_state, acc}
          end

        @model_event ->
          params = normalize_params(instruction.params)
          {record_model_event(acc_state, params), acc}

        @steer ->
          params = normalize_params(instruction.params)
          {next_state, generated} = build_steer_instructions(acc_state, params)
          {next_state, acc ++ generated}

        _ ->
          if action == ReAct.start_action() do
            next_state = acc_state |> Map.put(:model_events, []) |> Map.put(:model_error, nil)
            {next_state, acc ++ [instruction]}
          else
            {acc_state, acc ++ [instruction]}
          end
      end
    end)
  end

  defp build_steer_instructions(state, params) do
    state = ReactMachineExt.ensure(state)
    reason = map_get(params, :reason) || :steering
    request_id = map_get(params, :request_id) || state[:active_request_id]

    skipped_tool_calls = ReactMachineExt.unresolved_tool_calls(state)

    tool_result_instructions =
      Enum.map(skipped_tool_calls, fn tool ->
        instruction(ReAct.tool_result_action(), %{
          call_id: tool.id,
          result:
            {:error,
             %{
               type: "skipped",
               message: "Skipped due to queued user message"
             }}
        })
      end)

    cancel_instruction =
      instruction(ReAct.cancel_action(), %{request_id: request_id, reason: reason})

    state =
      state
      |> Map.put(:skipped_tool_calls, Enum.map(skipped_tool_calls, & &1.id))

    {state, tool_result_instructions ++ [cancel_instruction]}
  end

  defp put_ext_state(agent, fallback_state) do
    base_state =
      agent
      |> StratState.get(%{})
      |> maybe_restore_extra_field(:skipped_tool_calls, fallback_state)
      |> maybe_restore_extra_field(:llm_runtime, fallback_state)
      |> maybe_restore_extra_field(:model_events, fallback_state)
      |> maybe_restore_extra_field(:model_error, fallback_state)

    state =
      base_state
      |> ReactMachineExt.ensure()
      |> ReactMachineExt.sync_from_base()

    StratState.put(agent, state)
  end

  defp maybe_restore_extra_field(state, field, fallback_state) do
    if Map.has_key?(state, field) do
      state
    else
      Map.put(state, field, Map.get(fallback_state, field, []))
    end
  end

  defp instruction(action, params) do
    Jido.Instruction.new!(%{action: action, params: params})
  end

  defp normalize_action({action, _meta}), do: normalize_action(action)
  defp normalize_action(action), do: action

  defp normalize_params(%{} = params), do: params
  defp normalize_params(_), do: %{}

  defp rewrite_directives(agent, directives, fallback_state) do
    state =
      agent
      |> StratState.get(%{})
      |> Map.put_new(:llm_runtime, Map.get(fallback_state, :llm_runtime, %{candidates: []}))
      |> ensure_ext_state(%{})

    Enum.map(directives, fn
      %JidoLLMStream{} = directive ->
        candidates =
          state
          |> Map.get(:llm_runtime, %{})
          |> Map.get(:candidates, [])
          |> normalize_runtime_candidates(directive)

        base_payload = %{
          id: directive.id,
          context: directive.context,
          tools: directive.tools,
          tool_choice: directive.tool_choice,
          metadata: directive.metadata,
          candidates: candidates
        }

        payload =
          base_payload
          |> maybe_put(:system_prompt, directive.system_prompt)
          |> maybe_put(:timeout, directive.timeout)

        PrehenLLMStream.new!(payload)

      directive ->
        directive
    end)
  end

  defp normalize_runtime_candidates(candidates, directive)
       when is_list(candidates) and candidates != [] do
    Enum.map(candidates, &normalize_runtime_candidate(&1, directive))
  end

  defp normalize_runtime_candidates(_candidates, directive) do
    [
      %{
        provider_ref: "__runtime__",
        provider: provider_from_model_spec(directive.model),
        model_id: model_id_from_spec(directive.model),
        model_name: model_id_from_spec(directive.model),
        model: directive.model,
        params: %{
          temperature: directive.temperature,
          max_tokens: directive.max_tokens
        },
        request_opts: [],
        on_errors: []
      }
    ]
  end

  defp normalize_runtime_candidate(%{} = candidate, directive) do
    params =
      candidate
      |> map_get(:params, %{})
      |> Map.put_new(:temperature, directive.temperature)
      |> Map.put_new(:max_tokens, directive.max_tokens)

    %{
      provider_ref: map_get(candidate, :provider_ref, "__runtime__"),
      provider:
        map_get(candidate, :provider, provider_from_model_spec(map_get(candidate, :model))),
      model_id: map_get(candidate, :model_id, model_id_from_spec(map_get(candidate, :model))),
      model_name: map_get(candidate, :model_name, model_id_from_spec(map_get(candidate, :model))),
      model: map_get(candidate, :model, directive.model),
      params: params,
      request_opts: map_get(candidate, :request_opts, []),
      on_errors: map_get(candidate, :on_errors, [])
    }
  end

  defp normalize_runtime_candidate(_candidate, directive) do
    %{
      provider_ref: "__runtime__",
      provider: provider_from_model_spec(directive.model),
      model_id: model_id_from_spec(directive.model),
      model_name: model_id_from_spec(directive.model),
      model: directive.model,
      params: %{
        temperature: directive.temperature,
        max_tokens: directive.max_tokens
      },
      request_opts: [],
      on_errors: []
    }
  end

  defp record_model_event(state, params) do
    kind = map_get(params, :kind)

    if kind in [:selected, :fallback, :exhausted] do
      event =
        %{
          kind: kind,
          call_id: map_get(params, :call_id),
          model: map_get(params, :model),
          from_model: map_get(params, :from_model),
          to_model: map_get(params, :to_model),
          error_type: map_get(params, :error_type),
          error: map_get(params, :error)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      next_state =
        state
        |> Map.update(:model_events, [event], fn events -> events ++ [event] end)

      if kind == :exhausted do
        Map.put(next_state, :model_error, event)
      else
        next_state
      end
    else
      state
    end
  end

  defp ensure_ext_state(state, ctx) do
    state
    |> Map.put_new(:llm_runtime, extract_llm_runtime(ctx))
    |> Map.put_new(:model_events, [])
    |> Map.put_new(:model_error, nil)
  end

  defp extract_llm_runtime(ctx) when is_map(ctx) do
    opts = Map.get(ctx, :strategy_opts, [])
    normalize_llm_runtime(Keyword.get(opts, :llm_runtime, %{}))
  end

  defp extract_llm_runtime(_ctx), do: %{candidates: []}

  defp normalize_llm_runtime(%{candidates: candidates}) when is_list(candidates) do
    %{candidates: candidates}
  end

  defp normalize_llm_runtime(%{"candidates" => candidates}) when is_list(candidates) do
    %{candidates: candidates}
  end

  defp normalize_llm_runtime(_), do: %{candidates: []}

  defp map_get(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp map_get(map, key, default) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  defp provider_from_model_spec(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [provider, _model_id] when provider != "" -> provider
      _ -> "openai"
    end
  end

  defp provider_from_model_spec(_), do: "openai"

  defp model_id_from_spec(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [_provider, model_id] when model_id != "" -> model_id
      _ -> "gpt-5-mini"
    end
  end

  defp model_id_from_spec(_), do: "gpt-5-mini"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp gen_request_id do
    "req_#{System.unique_integer([:positive])}"
  end
end
