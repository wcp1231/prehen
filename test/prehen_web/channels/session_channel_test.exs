defmodule PrehenWeb.SessionChannelTest do
  use PrehenWeb.ChannelCase, async: false

  alias Prehen.Gateway.SessionRegistry

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
    :ok =
      SessionRegistry.put(%{
        gateway_session_id: "gw_1",
        worker_pid: self(),
        agent_name: "fake_stdio",
        agent_session_id: "agent_gw_1",
        status: :attached
      })

    {:ok, _, _socket} =
      socket(PrehenWeb.UserSocket)
      |> subscribe_and_join(PrehenWeb.SessionChannel, "session:gw_1")

    Phoenix.PubSub.broadcast(
      Prehen.PubSub,
      "session:gw_1",
      {:gateway_event,
       %{
         type: "session.output.delta",
         gateway_session_id: "gw_1",
         agent_session_id: "agent_gw_1",
         agent: "fake_stdio",
         seq: 1,
         payload: %{"text" => "hel"}
       }}
    )

    assert_push "event", %{"type" => "session.output.delta", "gateway_session_id" => "gw_1"}
  end

  test "returns clean attach error when gateway session does not exist" do
    assert {:error, %{"reason" => "session_not_found"}} =
             socket(PrehenWeb.UserSocket)
             |> subscribe_and_join(PrehenWeb.SessionChannel, "session:missing")
  end
end
