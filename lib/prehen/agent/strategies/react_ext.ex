defmodule Prehen.Agent.Strategies.ReactExt do
  @moduledoc false

  use Jido.Agent.Strategy

  alias Jido.Agent
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.AI.Strategies.ReAct
  alias Prehen.Agent.Strategies.ReactMachineExt

  @followup :prehen_react_followup
  @steer :prehen_react_steer

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

  def action_spec(action), do: ReAct.action_spec(action)

  @impl true
  def signal_routes(ctx) do
    ReAct.signal_routes(ctx) ++
      [
        {"ai.session.steer", {:strategy_cmd, @steer}},
        {"ai.session.follow_up", {:strategy_cmd, @followup}}
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

    %{snapshot | details: details}
  end

  @impl true
  def init(%Agent{} = agent, ctx) do
    {agent, directives} = ReAct.init(agent, ctx)
    {put_ext_state(agent, %{}), directives}
  end

  @impl true
  def cmd(%Agent{} = agent, instructions, ctx) do
    state = agent |> StratState.get(%{}) |> ReactMachineExt.ensure()
    {state, rewritten} = rewrite_instructions(state, instructions)
    agent = StratState.put(agent, state)

    {agent, directives} = ReAct.cmd(agent, rewritten, ctx)
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

        @steer ->
          params = normalize_params(instruction.params)
          {next_state, generated} = build_steer_instructions(acc_state, params)
          {next_state, acc ++ generated}

        _ ->
          {acc_state, acc ++ [instruction]}
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

  defp map_get(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp gen_request_id do
    "req_#{System.unique_integer([:positive])}"
  end
end
