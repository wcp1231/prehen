defmodule Prehen.Integration.PlatformRuntimeTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Profile
  alias Prehen.Agents.Registry
  alias Prehen.Client.Surface
  import Phoenix.ConnTest

  @endpoint PrehenWeb.Endpoint

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

  test "control plane HTTP endpoints route through gateway sessions" do
    conn = build_conn()

    conn = post(conn, "/sessions", %{"agent" => "fake_stdio"})
    assert created = json_response(conn, 201)
    assert %{"session_id" => session_id, "agent" => "fake_stdio"} = created

    on_exit(fn -> Surface.stop_session(session_id) end)

    conn = post(build_conn(), "/sessions/#{session_id}/messages", %{"text" => "hello from http"})
    assert submitted = json_response(conn, 202)

    assert submitted["status"] == "accepted"
    assert submitted["session_id"] == session_id
    assert is_binary(submitted["request_id"])

    conn = get(build_conn(), "/agents")
    assert agents = json_response(conn, 200)

    assert Enum.any?(agents["agents"], fn agent ->
             agent["agent"] == "fake_stdio"
           end)
  end
end
