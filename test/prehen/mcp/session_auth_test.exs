defmodule Prehen.MCP.SessionAuthTest do
  use ExUnit.Case, async: false

  alias Prehen.MCP.SessionAuth

  setup do
    case Process.whereis(SessionAuth) do
      nil ->
        start_supervised!(SessionAuth)

      _pid ->
        :ok = SessionAuth.reset()
    end

    :ok
  end

  test "issues and invalidates session-bound bearer tokens" do
    assert {:ok, token} = SessionAuth.issue("gw_1", "coder")
    assert {:ok,
            %{
              session_id: "gw_1",
              profile_id: "coder",
              capabilities: ["skills.load", "skills.search"]
            }} = SessionAuth.lookup(token)
    assert :ok = SessionAuth.invalidate(token)
    assert {:error, :not_found} = SessionAuth.lookup(token)
  end
end
