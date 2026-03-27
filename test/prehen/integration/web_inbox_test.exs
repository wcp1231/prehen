defmodule Prehen.Integration.WebInboxTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint PrehenWeb.Endpoint

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
end
