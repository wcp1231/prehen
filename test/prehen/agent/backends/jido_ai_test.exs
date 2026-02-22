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
      workspace_dir: Application.fetch_env!(:prehen, :workspace_dir),
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

  test "keeps llm runtime options isolated across concurrently started agents" do
    workspace_dir = Application.fetch_env!(:prehen, :workspace_dir)

    config1 = %{
      model: "openai:gpt-5-mini",
      model_candidates: [
        %{
          model: "openai:gpt-5-mini",
          params: %{temperature: 0.1},
          request_opts: [api_key: "sk-a", base_url: "https://provider-a.test/v1"],
          on_errors: []
        }
      ],
      max_steps: 3,
      timeout_ms: 1_000,
      workspace_dir: workspace_dir,
      read_max_bytes: 8_192
    }

    config2 = %{
      model: "openai:gpt-5-mini",
      model_candidates: [
        %{
          model: "openai:gpt-5-mini",
          params: %{temperature: 0.2},
          request_opts: [api_key: "sk-b", base_url: "https://provider-b.test/v1"],
          on_errors: []
        }
      ],
      max_steps: 3,
      timeout_ms: 1_000,
      workspace_dir: workspace_dir,
      read_max_bytes: 8_192
    }

    assert {:ok, %{pid: pid1} = handle1} = JidoAI.start_agent(config1)
    assert {:ok, %{pid: pid2} = handle2} = JidoAI.start_agent(config2)

    on_exit(fn ->
      JidoAI.stop_agent(handle1)
      JidoAI.stop_agent(handle2)
    end)

    {:ok, status1} = Jido.AgentServer.status(pid1)
    {:ok, status2} = Jido.AgentServer.status(pid2)

    candidates1 = get_in(status1.raw_state, [:__strategy__, :llm_runtime, :candidates]) || []
    candidates2 = get_in(status2.raw_state, [:__strategy__, :llm_runtime, :candidates]) || []

    assert hd(candidates1).request_opts[:base_url] == "https://provider-a.test/v1"
    assert hd(candidates2).request_opts[:base_url] == "https://provider-b.test/v1"
  end
end
