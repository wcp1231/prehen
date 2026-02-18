defmodule Prehen.Agent.Backends.JidoAITest do
  use ExUnit.Case

  alias Prehen.Agent.Backends.JidoAI

  test "starts agent with ReactExt strategy and session queue fields" do
    config = %{
      model: "openai:gpt-5-mini",
      api_key: nil,
      base_url: nil,
      max_steps: 3,
      timeout_ms: 1_000,
      root_dir: Path.expand("."),
      read_max_bytes: 8_192
    }

    assert {:ok, %{module: module, pid: pid} = handle} = JidoAI.start_agent(config)
    on_exit(fn -> JidoAI.stop_agent(handle) end)

    assert module.strategy() == Prehen.Agent.Strategies.ReactExt

    {:ok, status} = Jido.AgentServer.status(pid)
    strategy_state = get_in(status.raw_state, [:__strategy__])

    assert is_list(strategy_state.prompt_q)
    assert is_list(strategy_state.steer_q)
    assert is_list(strategy_state.followup_q)
    assert strategy_state.turn_phase in [:idle, :llm, :tools, :finalizing]

    routes = module.strategy().signal_routes(%{})
    route_map = Map.new(routes)

    assert route_map["ai.session.steer"] == {:strategy_cmd, :prehen_react_steer}
    assert route_map["ai.session.follow_up"] == {:strategy_cmd, :prehen_react_followup}
  end
end
