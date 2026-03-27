defmodule Prehen.Agents.Transports.StdioTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Transport
  alias Prehen.Agents.Protocol.Frame
  alias Prehen.Agents.Transports.Stdio
  alias Prehen.Agents.Profile

  test "transport behaviour exposes generic inbound frame consumption" do
    assert {:recv_frame, 2} in Transport.behaviour_info(:callbacks)
  end

  test "builds a session.open frame with gateway metadata" do
    frame =
      Frame.session_open(
        gateway_session_id: "gw_1",
        agent: "fake_stdio",
        workspace: "/tmp/demo"
      )

    assert frame.type == "session.open"
    assert frame.payload.gateway_session_id == "gw_1"
    refute Map.has_key?(frame.payload, :emit_stderr?)
  end

  test "opens a session and returns the agent_session_id from the child process" do
    profile = %Profile{
      name: "fake_stdio",
      command: ["mix", "run", "--no-start", "test/support/fake_stdio_agent.exs"]
    }

    assert {:ok, transport} = Stdio.start_link(profile: profile, gateway_session_id: "gw_1")

    assert {:ok, %{agent_session_id: "agent_gw_1"}} =
             Stdio.open_session(transport, %{workspace: "/tmp/demo"})

    assert :ok = Stdio.stop(transport)
  end

  test "ignores stderr diagnostics while waiting for session.opened" do
    profile = %Profile{
      name: "fake_stdio",
      command: ["mix", "run", "--no-start", "test/support/fake_stdio_agent.exs"],
      env: %{"FAKE_STDIO_EMIT_STDERR" => "1"}
    }

    assert {:ok, transport} = Stdio.start_link(profile: profile, gateway_session_id: "gw_2")
    assert {:ok, %{agent_session_id: "agent_gw_2"}} = Stdio.open_session(transport, %{})
    assert Process.alive?(transport)
    assert :ok = Stdio.stop(transport)
  end

  test "sends a session.message frame and receives the output delta frame" do
    profile = %Profile{
      name: "fake_stdio",
      command: ["mix", "run", "--no-start", "test/support/fake_stdio_agent.exs"]
    }

    assert {:ok, transport} = Stdio.start_link(profile: profile, gateway_session_id: "gw_3")

    assert {:ok, %{agent_session_id: "agent_gw_3"}} = Stdio.open_session(transport, %{})

    assert :ok =
             Stdio.send_message(transport, %{
               agent_session_id: "agent_gw_3",
               message_id: "message_123"
             })

    assert {:ok,
            %{
              "type" => "session.output.delta",
              "payload" => %{
                "agent_session_id" => "agent_gw_3",
                "message_id" => "message_123",
                "text" => "hi"
              }
            }} = Transport.recv_frame(transport, 1_000)

    assert :ok = Stdio.stop(transport)
  end

  test "rejects a second concurrent recv_frame waiter" do
    profile = %Profile{
      name: "fake_stdio",
      command: ["mix", "run", "--no-start", "test/support/fake_stdio_agent.exs"]
    }

    assert {:ok, transport} = Stdio.start_link(profile: profile, gateway_session_id: "gw_4")
    assert {:ok, %{agent_session_id: "agent_gw_4"}} = Stdio.open_session(transport, %{})

    waiter =
      Task.async(fn ->
        Transport.recv_frame(transport, 5_000)
      end)

    Process.sleep(50)

    assert {:error, :recv_waiter_already_registered} = Transport.recv_frame(transport, 100)

    assert :ok =
             Stdio.send_message(transport, %{
               agent_session_id: "agent_gw_4",
               message_id: "message_456"
             })

    assert {:ok,
            %{
              "type" => "session.output.delta",
              "payload" => %{
                "agent_session_id" => "agent_gw_4",
                "message_id" => "message_456",
                "text" => "hi"
              }
            }} = Task.await(waiter, 1_000)

    assert :ok = Stdio.stop(transport)
  end
end
