defmodule PrehenWeb.SessionChannel do
  use Phoenix.Channel

  alias Prehen.Client.Surface
  alias PrehenWeb.EventSerializer

  @impl true
  def join("session:" <> session_id, params, socket) do
    case Surface.resume_session(session_id) do
      {:ok, %{session_pid: session_pid}} ->
        ref = Process.monitor(session_pid)

        # Subscribe first so live events queue in the process mailbox
        case Surface.subscribe_events(session_id) do
          {:ok, _} ->
            last_seq = params["last_seq"] || 0

            # Replay missed events and track the max seq we pushed
            max_replayed_seq =
              if last_seq > 0 do
                replay_missed_events(socket, session_id, last_seq)
              else
                0
              end

            socket =
              socket
              |> assign(:session_id, session_id)
              |> assign(:session_pid, session_pid)
              |> assign(:monitor_ref, ref)
              |> assign(:last_seq, max(last_seq, max_replayed_seq))

            {:ok, %{"session_id" => session_id}, socket}

          {:error, reason} ->
            Process.demonitor(ref, [:flush])
            {:error, %{"reason" => inspect(reason)}}
        end

      {:error, %{code: _} = err} ->
        {:error, %{"reason" => err[:message] || "session_not_found"}}

      {:error, _reason} ->
        {:error, %{"reason" => "session_not_found"}}
    end
  end

  @impl true
  def handle_in("submit", %{"text" => text} = payload, socket) do
    kind = payload |> Map.get("kind", "prompt") |> normalize_kind()

    case Surface.submit_message(socket.assigns.session_pid, text, kind: kind) do
      {:ok, ack} ->
        {:reply, {:ok, %{"request_id" => ack.request_id}}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{"reason" => "session_unavailable"}}, socket}
    end
  end

  def handle_in("submit", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_text_field"}}, socket}
  end

  @impl true
  def handle_info({:session_event, record}, socket) do
    seq = record[:seq] || record["seq"] || 0

    # Deduplicate: skip events already pushed during replay
    if seq > 0 and seq <= socket.assigns.last_seq do
      {:noreply, socket}
    else
      serialized = EventSerializer.serialize(record)
      socket = assign(socket, :last_seq, max(socket.assigns.last_seq, seq))
      push(socket, "event", serialized)
      {:noreply, socket}
    end
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

  # Replays events with seq > last_seq. Returns the max seq pushed.
  defp replay_missed_events(socket, session_id, last_seq) do
    Surface.replay_session(session_id)
    |> Enum.filter(fn record ->
      seq = record[:seq] || record["seq"] || 0
      seq > last_seq
    end)
    |> Enum.reduce(last_seq, fn record, max_seq ->
      push(socket, "event", EventSerializer.serialize(record))
      seq = record[:seq] || record["seq"] || 0
      max(max_seq, seq)
    end)
  end

  defp normalize_kind("prompt"), do: :prompt
  defp normalize_kind("steering"), do: :steering
  defp normalize_kind("steer"), do: :steering
  defp normalize_kind("follow_up"), do: :follow_up
  defp normalize_kind(_), do: :prompt
end
