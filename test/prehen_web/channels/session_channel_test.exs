defmodule PrehenWeb.SessionChannelTest do
  use PrehenWeb.ChannelCase, async: false

  test "forwards gateway envelopes as event pushes on handle_info" do
    socket =
      socket(PrehenWeb.UserSocket, "user_1", %{})
      |> Phoenix.Socket.assign(:session_id, "gw_1")
      |> Map.put(:topic, "session:gw_1")
      |> Map.put(:joined, true)
      |> Map.put(:join_ref, "1")

    event = %{
      "type" => "session.output.delta",
      "gateway_session_id" => "gw_1",
      "agent_session_id" => "agent_gw_1",
      "agent" => "fake_stdio",
      "node" => "nonode@nohost",
      "seq" => 1,
      "timestamp" => 1_000,
      "payload" => %{"text" => "hel"},
      "metadata" => %{}
    }

    assert {:noreply, returned_socket} =
             PrehenWeb.SessionChannel.handle_info({:gateway_event, event}, socket)

    assert returned_socket.assigns.session_id == "gw_1"

    assert_push "event", %{
      "type" => "session.output.delta",
      "gateway_session_id" => "gw_1",
      "agent_session_id" => "agent_gw_1"
    }
  end

  test "pushes normalized gateway envelopes to subscribers" do
    {:ok, _, _socket} =
      socket(PrehenWeb.UserSocket)
      |> subscribe_and_join(PrehenWeb.SessionChannel, "session:gw_1")

    assert_push "event", %{"type" => "session.output.delta", "gateway_session_id" => "gw_1"}
  end
end
