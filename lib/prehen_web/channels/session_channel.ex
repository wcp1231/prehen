defmodule PrehenWeb.SessionChannel do
  use Phoenix.Channel

  alias Prehen.Client.Surface
  alias Prehen.Gateway.SessionRegistry
  alias PrehenWeb.EventSerializer

  @impl true
  def join("session:" <> session_id, _params, socket) do
    with {:ok, worker_pid} <- SessionRegistry.fetch_worker(session_id),
         {:ok, session} <- SessionRegistry.fetch(session_id) do
        :ok = Phoenix.PubSub.subscribe(Prehen.PubSub, "session:#{session_id}")
        monitor_ref = Process.monitor(worker_pid)

        socket =
          socket
          |> assign(:session_id, session_id)
          |> assign(:worker_pid, worker_pid)
          |> assign(:monitor_ref, monitor_ref)

        {:ok, join_payload(session_id, session), socket}
    else
      {:error, :not_found} ->
        {:error, %{"reason" => "session_not_found"}}

      {:error, reason} ->
        {:error, %{"reason" => inspect(reason)}}
    end
  end

  @impl true
  def handle_in("submit", %{"text" => text} = payload, socket) do
    kind = payload |> Map.get("kind", "prompt") |> normalize_kind()

    case Surface.submit_message(socket.assigns.session_id, text, kind: kind) do
      {:ok, ack} ->
        {:reply, {:ok, %{"request_id" => ack.request_id}}, socket}

      {:error, _reason} ->
        {:reply,
         {:error,
          %{
            "reason" => "session_unavailable",
            "session_id" => socket.assigns.session_id
          }}, socket}
    end
  end

  def handle_in("submit", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_text_field"}}, socket}
  end

  @impl true
  def handle_info({:gateway_event, event}, socket) do
    push(socket, "event", EventSerializer.serialize(event))
    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{monitor_ref: ref}} = socket) do
    event_type =
      case reason do
        :normal -> "session.ended"
        :shutdown -> "session.ended"
        {:shutdown, _} -> "session.ended"
        _ -> "session.crashed"
      end

    push(socket, "event", %{
      "type" => event_type,
      "session_id" => socket.assigns.session_id,
      "reason" => inspect(reason)
    })

    {:stop, :normal, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if ref = socket.assigns[:monitor_ref] do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp normalize_kind("prompt"), do: :prompt
  defp normalize_kind("steering"), do: :steering
  defp normalize_kind("steer"), do: :steering
  defp normalize_kind("follow_up"), do: :follow_up
  defp normalize_kind(_), do: :prompt

  defp join_payload(session_id, session) do
    %{
      "session_id" => session_id,
      "status" => session |> Map.get(:status) |> to_string(),
      "agent_name" => Map.get(session, :agent_name)
    }
  end
end
