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

    on_exit(fn -> SessionRegistry.delete("gw_1") end)

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

  test "returns inbox-friendly metadata in the join payload" do
    worker_pid = spawn(fn -> receive do :stop -> :ok end end)

    :ok =
      SessionRegistry.put(%{
        gateway_session_id: "gw_join",
        worker_pid: worker_pid,
        agent_name: "fake_stdio",
        agent_session_id: "agent_gw_join",
        status: :running
      })

    on_exit(fn ->
      SessionRegistry.delete("gw_join")
      Process.exit(worker_pid, :kill)
    end)

    assert {:ok,
            %{
              "session_id" => "gw_join",
              "status" => "running",
              "agent_name" => "fake_stdio"
            }, _socket} =
             socket(PrehenWeb.UserSocket)
             |> subscribe_and_join(PrehenWeb.SessionChannel, "session:gw_join")
  end

  test "returns clean attach error when gateway session does not exist" do
    assert {:error, %{"reason" => "session_not_found"}} =
             socket(PrehenWeb.UserSocket)
             |> subscribe_and_join(PrehenWeb.SessionChannel, "session:missing")
  end

  test "fails attach when registry route points to a dead worker" do
    worker_pid = spawn(fn -> :ok end)
    ref = Process.monitor(worker_pid)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, _reason}, 1_000

    :ok =
      SessionRegistry.put(%{
        gateway_session_id: "gw_dead",
        worker_pid: worker_pid,
        agent_name: "fake_stdio",
        agent_session_id: "agent_gw_dead",
        status: :attached
      })

    on_exit(fn -> SessionRegistry.delete("gw_dead") end)

    assert {:error, %{"reason" => "session_not_found"}} =
             socket(PrehenWeb.UserSocket)
             |> subscribe_and_join(PrehenWeb.SessionChannel, "session:gw_dead")
  end

  test "pushes a terminal event when monitored worker goes down" do
    worker_pid = spawn(fn -> receive do :stop -> :ok end end)

    :ok =
      SessionRegistry.put(%{
        gateway_session_id: "gw_down",
        worker_pid: worker_pid,
        agent_name: "fake_stdio",
        agent_session_id: "agent_gw_down",
        status: :attached
      })

    on_exit(fn -> SessionRegistry.delete("gw_down") end)

    {:ok, _, _socket} =
      socket(PrehenWeb.UserSocket)
      |> subscribe_and_join(PrehenWeb.SessionChannel, "session:gw_down")

    Process.exit(worker_pid, :kill)

    assert_push "event", %{
      "type" => "session.crashed",
      "session_id" => "gw_down"
    }
  end

  test "returns a submit ack payload the inbox browser can correlate" do
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

    assert {:ok, %{session_id: session_id}} =
             Prehen.Client.Surface.create_session(agent: "fake_stdio")

    on_exit(fn -> Prehen.Client.Surface.stop_session(session_id) end)

    {:ok, _, socket} =
      socket(PrehenWeb.UserSocket)
      |> subscribe_and_join(PrehenWeb.SessionChannel, "session:#{session_id}")

    ref = push(socket, "submit", %{"text" => "hello"})
    assert_reply ref, :ok, %{"request_id" => _request_id}
  end

  test "rejects malformed submit text with a structured error" do
    socket =
      socket(PrehenWeb.UserSocket, "user_1", %{})
      |> Phoenix.Socket.assign(:session_id, "gw_malformed")

    assert {:reply, {:error, %{"reason" => "missing_text_field"}}, returned_socket} =
             PrehenWeb.SessionChannel.handle_in("submit", %{"text" => 123}, socket)

    assert returned_socket.assigns.session_id == "gw_malformed"
  end

  test "rejects blank submit text with a structured error" do
    socket =
      socket(PrehenWeb.UserSocket, "user_1", %{})
      |> Phoenix.Socket.assign(:session_id, "gw_blank")

    assert {:reply, {:error, %{"reason" => "missing_text_field"}}, returned_socket} =
             PrehenWeb.SessionChannel.handle_in("submit", %{"text" => "   "}, socket)

    assert returned_socket.assigns.session_id == "gw_blank"
  end

  test "returns submit failures with the unavailable session id" do
    socket =
      socket(PrehenWeb.UserSocket, "user_1", %{})
      |> Phoenix.Socket.assign(:session_id, "missing_session")

    assert {:reply,
            {:error,
             %{"reason" => "session_unavailable", "session_id" => "missing_session"}},
            returned_socket} =
             PrehenWeb.SessionChannel.handle_in("submit", %{"text" => "hello"}, socket)

    assert returned_socket.assigns.session_id == "missing_session"
  end

  test "returns session unavailable for retained terminal sessions" do
    :ok =
      SessionRegistry.put(%{
        gateway_session_id: "gw_terminal",
        worker_pid: nil,
        agent_name: "fake_stdio",
        agent_session_id: "agent_gw_terminal",
        status: :stopped
      })

    on_exit(fn -> SessionRegistry.delete("gw_terminal") end)

    socket =
      socket(PrehenWeb.UserSocket, "user_1", %{})
      |> Phoenix.Socket.assign(:session_id, "gw_terminal")

    assert {:reply,
            {:error, %{"reason" => "session_unavailable", "session_id" => "gw_terminal"}},
            returned_socket} =
             PrehenWeb.SessionChannel.handle_in("submit", %{"text" => "hello"}, socket)

    assert returned_socket.assigns.session_id == "gw_terminal"
  end
end
