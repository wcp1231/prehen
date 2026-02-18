defmodule Prehen.Agent.Strategies.ReactExtTest do
  use ExUnit.Case

  alias Jido.Agent
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.AI.Thread
  alias Prehen.Agent.Strategies.{ReactExt, ReactMachineExt}

  test "signal_routes include session steer/follow_up types" do
    routes = ReactExt.signal_routes(%{})
    route_map = Map.new(routes)

    assert route_map["ai.session.steer"] == {:strategy_cmd, :prehen_react_steer}
    assert route_map["ai.session.follow_up"] == {:strategy_cmd, :prehen_react_followup}
  end

  test "machine extension ensures queue and phase fields" do
    state = ReactMachineExt.ensure(%{status: :awaiting_tool})

    assert state.prompt_q == []
    assert state.steer_q == []
    assert state.followup_q == []
    assert state.turn_phase == :tools
    assert state.pending_tool_calls == []
  end

  test "steer command injects skipped tool results based on pending tool calls" do
    ctx = %{
      strategy_opts: [
        tools: [Prehen.Actions.LS, Prehen.Actions.Read],
        model: "openai:gpt-5-mini",
        max_iterations: 4,
        request_policy: :reject
      ],
      agent_module: __MODULE__
    }

    {agent, _} = ReactExt.init(%Agent{id: "agent_1", state: %{}}, ctx)

    seeded_strategy_state =
      agent
      |> StratState.get(%{})
      |> Map.put(:status, :awaiting_tool)
      |> Map.put(:active_request_id, "req_1")
      |> Map.put(:thread, Thread.new(system_prompt: "test"))
      |> Map.put(:run_tool_context, %{})
      |> Map.put(:pending_tool_calls, [
        %{id: "tool_1", name: "ls", arguments: %{"path" => "."}, result: nil},
        %{id: "tool_2", name: "read", arguments: %{"path" => "README.md"}, result: nil}
      ])

    agent = StratState.put(agent, seeded_strategy_state)

    instruction =
      Jido.Instruction.new!(%{
        action: :prehen_react_steer,
        params: %{request_id: "req_1", reason: :steering}
      })

    {updated, directives} = ReactExt.cmd(agent, [instruction], ctx)
    updated_strategy_state = StratState.get(updated, %{})

    assert "tool_1" in updated_strategy_state.skipped_tool_calls
    assert "tool_2" in updated_strategy_state.skipped_tool_calls
    assert is_list(directives)
  end
end
