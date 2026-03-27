defmodule Prehen.Client.SurfaceTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Profile
  alias Prehen.Agents.Registry
  alias Prehen.Client.Surface
  alias Prehen.Gateway.Router
  alias Prehen.Gateway.SessionRegistry

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

  test "application boots gateway registry runtime children" do
    assert is_pid(Process.whereis(Prehen.Gateway.Supervisor))
    assert {:ok, [%Prehen.Agents.Profile{name: "fake_stdio"}]} = {:ok, Registry.all()}
    assert {:ok, %Prehen.Agents.Profile{name: "fake_stdio"}} = Router.select_agent()
  end

  test "create_session starts a gateway session and returns gateway metadata" do
    assert {:ok, %{session_id: gateway_session_id, agent: "fake_stdio"}} =
             Surface.create_session(agent: "fake_stdio")

    assert is_binary(gateway_session_id)
    assert {:ok, %{status: :attached}} = SessionRegistry.fetch(gateway_session_id)

    assert :ok = Surface.stop_session(gateway_session_id)
  end

  test "submit_message and session_status use gateway session ids" do
    assert {:ok, %{session_id: session_id}} = Surface.create_session(agent: "fake_stdio")

    on_exit(fn ->
      Surface.stop_session(session_id)
    end)

    assert {:ok, submit} = Surface.submit_message(session_id, "hello gateway")
    assert submit.status == :accepted
    assert submit.session_id == session_id
    assert is_binary(submit.request_id)

    assert {:ok, status} = Surface.session_status(session_id)
    assert status.session_id == session_id
    assert status.status == :attached
    assert status.agent_name == "fake_stdio"
    assert is_binary(status.agent_session_id)
  end
end
