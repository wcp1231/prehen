defmodule PrehenTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Profile
  alias Prehen.Agents.Registry

  setup do
    registry_pid = Process.whereis(Registry)
    original = :sys.get_state(registry_pid)

    fake_profile = %Profile{
      name: "fake_stdio",
      command: ["mix", "run", "--no-start", "test/support/fake_stdio_agent.exs"]
    }

    :sys.replace_state(registry_pid, fn _state ->
      %{ordered: [fake_profile], by_name: %{"fake_stdio" => fake_profile}}
    end)

    on_exit(fn ->
      :sys.replace_state(registry_pid, fn _state -> original end)
    end)

    :ok
  end

  test "run/2 executes through the gateway MVP path and returns gateway trace" do
    assert {:ok, result} = Prehen.run("say hi", agent: "fake_stdio")

    assert result.status == :ok
    assert result.answer == "hi"
    assert is_binary(result.session_id)
    assert Enum.any?(result.trace, &(&1.type == "agent.started"))
    assert Enum.any?(result.trace, &(&1.type == "session.output.delta"))
    assert Enum.all?(result.trace, &(&1.source == "prehen.gateway"))
  end

  test "public session api uses gateway session id for submit/status/stop" do
    assert {:ok, %{session_id: session_id, agent: "fake_stdio"}} =
             Prehen.create_session(agent: "fake_stdio")

    on_exit(fn -> Prehen.stop_session(session_id) end)

    assert {:ok, %{status: :accepted, session_id: ^session_id}} =
             Prehen.submit_message(session_id, "first", kind: :prompt)

    assert {:ok, status} = Prehen.session_status(session_id)
    assert status.session_id == session_id
    assert status.status == :running
    assert status.agent_name == "fake_stdio"
    assert is_binary(status.agent_session_id)

    assert :ok = Prehen.stop_session(session_id)

    assert {:ok, stopped_status} = Prehen.session_status(session_id)
    assert stopped_status.session_id == session_id
    assert stopped_status.status == :stopped
    assert stopped_status.agent_name == "fake_stdio"
    assert is_binary(stopped_status.agent_session_id)
  end

  test "run/2 reports a gateway error for a missing reused session" do
    assert {:error, %{type: :runtime_failed, reason: {:gateway_session_not_found, "missing"}}} =
             Prehen.run("say hi", session_id: "missing", timeout_ms: 100)
  end
end
