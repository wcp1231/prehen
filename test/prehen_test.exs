defmodule PrehenTest do
  use ExUnit.Case, async: false

  alias Prehen.TestSupport.PiAgentFixture

  setup do
    original = PiAgentFixture.replace_registry!(PiAgentFixture.registry_state("coder"))
    prehen_home = tmp_prehen_home("prehen_test")
    previous_prehen_home = System.get_env("PREHEN_HOME")

    System.put_env("PREHEN_HOME", prehen_home)
    write_profile_home!(prehen_home, "coder")

    on_exit(fn ->
      PiAgentFixture.restore_registry!(original)
      restore_prehen_home(previous_prehen_home)
      File.rm_rf(prehen_home)
    end)

    {:ok, prehen_home: prehen_home}
  end

  test "run/2 executes through the gateway MVP path and returns gateway trace" do
    assert {:ok, result} = Prehen.run("say hi", agent: "coder")

    assert result.status == :ok
    assert result.answer == "echo:say hi"
    assert is_binary(result.session_id)
    assert Enum.any?(result.trace, &(&1.type == "agent.started"))
    assert Enum.any?(result.trace, &(&1.type == "session.output.delta"))
    assert Enum.all?(result.trace, &(&1.source == "prehen.gateway"))
  end

  test "public session api uses gateway session id for submit/status/stop" do
    assert {:ok, %{session_id: session_id, agent: "coder"}} =
             Prehen.create_session(agent: "coder")

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

  defp write_profile_home!(prehen_home, profile_name) do
    profile_dir = Path.join([prehen_home, "profiles", profile_name])
    File.mkdir_p!(profile_dir)
    File.write!(Path.join(profile_dir, "SOUL.md"), "SOUL for #{profile_name}.\n")
    File.write!(Path.join(profile_dir, "AGENTS.md"), "AGENTS for #{profile_name}.\n")
  end

  defp tmp_prehen_home(label) do
    Path.join(
      System.tmp_dir!(),
      "prehen_public_api_#{label}_#{System.unique_integer([:positive])}"
    )
  end

  defp restore_prehen_home(nil), do: System.delete_env("PREHEN_HOME")
  defp restore_prehen_home(value), do: System.put_env("PREHEN_HOME", value)
end
