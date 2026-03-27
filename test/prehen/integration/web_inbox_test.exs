defmodule Prehen.Integration.WebInboxTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint PrehenWeb.Endpoint

  test "lists sessions for the inbox page" do
    conn = get(build_conn(), "/inbox/sessions")

    assert %{"sessions" => sessions} = json_response(conn, 200)
    assert is_list(sessions)
  end

  test "lists agents with a default flag when profiles exist" do
    fake_profile = %Prehen.Agents.Profile{
      name: "fake_stdio",
      command: ["mix", "run", "--no-start", "test/support/fake_stdio_agent.exs"]
    }

    registry_pid = Process.whereis(Prehen.Agents.Registry)
    original = :sys.get_state(registry_pid)

    :sys.replace_state(registry_pid, fn _ ->
      %{ordered: [fake_profile], by_name: %{"fake_stdio" => fake_profile}}
    end)

    on_exit(fn ->
      :sys.replace_state(registry_pid, fn _ -> original end)
    end)

    conn = get(build_conn(), "/agents")

    assert %{"agents" => agents} = json_response(conn, 200)
    assert is_list(agents)
    assert Enum.any?(agents, &Map.has_key?(&1, "default"))
  end

  test "returns an empty list when the registry is empty" do
    registry_pid = Process.whereis(Prehen.Agents.Registry)
    original = :sys.get_state(registry_pid)

    :sys.replace_state(registry_pid, fn _ ->
      %{ordered: [], by_name: %{}}
    end)

    on_exit(fn ->
      :sys.replace_state(registry_pid, fn _ -> original end)
    end)

    conn = get(build_conn(), "/agents")

    assert %{"agents" => agents} = json_response(conn, 200)
    assert agents == []
  end
end
