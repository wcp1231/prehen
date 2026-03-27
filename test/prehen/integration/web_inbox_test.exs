defmodule Prehen.Integration.WebInboxTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint PrehenWeb.Endpoint

  setup do
    maybe_reset_inbox_projection()
    :ok
  end

  test "lists sessions for the inbox page" do
    conn = get(build_conn(), "/inbox/sessions")

    assert %{"sessions" => []} = json_response(conn, 200)
  end

  test "lists agents for the inbox page" do
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
    assert [%{"agent" => "fake_stdio", "name" => "fake_stdio"}] = agents
  end

  defp maybe_reset_inbox_projection do
    module = Prehen.Gateway.InboxProjection

    if Code.ensure_loaded?(module) and function_exported?(module, :reset, 0) do
      apply(module, :reset, [])
    end
  end
end
