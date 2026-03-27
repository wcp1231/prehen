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
    conn = get(build_conn(), "/agents")

    assert %{"agents" => agents} = json_response(conn, 200)
    assert is_list(agents)

    case agents do
      [] ->
        :ok

      [first | _] ->
        assert Map.has_key?(first, "agent")
        assert Map.has_key?(first, "name")
    end
  end

  defp maybe_reset_inbox_projection do
    module = Prehen.Gateway.InboxProjection

    if Code.ensure_loaded?(module) and function_exported?(module, :reset, 0) do
      apply(module, :reset, [])
    end
  end
end
