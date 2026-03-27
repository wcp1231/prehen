defmodule Prehen.Agents.Transports.StdioTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Transports.Stdio
  alias Prehen.Agents.Profile

  test "opens a session and returns the agent_session_id from the child process" do
    profile = %Profile{
      name: "fake_stdio",
      command: ["elixir", "test/support/fake_stdio_agent.exs"]
    }

    assert {:ok, transport} = Stdio.start_link(profile: profile, gateway_session_id: "gw_1")
    assert {:ok, %{agent_session_id: "agent_gw_1"}} = Stdio.open_session(transport, %{})
  end
end
