defmodule PrehenTest do
  use ExUnit.Case, async: false

  alias Prehen.TestSupport.PiAgentFixture

  setup do
    original = PiAgentFixture.replace_registry!(PiAgentFixture.registry_state("coder"))
    workspace = PiAgentFixture.workspace!("prehen_test")

    on_exit(fn ->
      PiAgentFixture.restore_registry!(original)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "run/2 executes through the gateway MVP path and returns gateway trace", %{
    workspace: workspace
  } do
    assert {:ok, result} = Prehen.run("say hi", agent: "coder", workspace: workspace)

    assert result.status == :ok
    assert result.answer == "echo:say hi"
    assert is_binary(result.session_id)
    assert Enum.any?(result.trace, &(&1.type == "agent.started"))
    assert Enum.any?(result.trace, &(&1.type == "session.output.delta"))
    assert Enum.all?(result.trace, &(&1.source == "prehen.gateway"))
  end

  test "public session api uses gateway session id for submit/status/stop", %{
    workspace: workspace
  } do
    assert {:ok, %{session_id: session_id, agent: "coder"}} =
             Prehen.create_session(agent: "coder", workspace: workspace)

    on_exit(fn -> Prehen.stop_session(session_id) end)

    assert {:ok, %{status: :accepted, session_id: ^session_id}} =
             Prehen.submit_message(session_id, "first", kind: :prompt)

    assert {:ok, status} = Prehen.session_status(session_id)
    assert status.session_id == session_id
    assert status.status == :running
    assert status.agent_name == "coder"
    assert is_binary(status.agent_session_id)
    refute Map.has_key?(status, :worker_pid)

    assert :ok = Prehen.stop_session(session_id)

    assert {:ok, stopped_status} = Prehen.session_status(session_id)
    assert stopped_status.session_id == session_id
    assert stopped_status.status == :stopped
    assert stopped_status.agent_name == "coder"
    assert is_binary(stopped_status.agent_session_id)
    refute Map.has_key?(stopped_status, :worker_pid)
  end

  test "run/2 reports a gateway error for a missing reused session" do
    assert {:error, %{type: :runtime_failed, reason: {:gateway_session_not_found, "missing"}}} =
             Prehen.run("say hi", session_id: "missing", timeout_ms: 100)
  end
end
