defmodule PrehenWeb.SessionChannel do
  use Phoenix.Channel

  alias Prehen.Client.Surface
  alias Prehen.Gateway.SessionRegistry
  alias PrehenWeb.EventSerializer

  @impl true
  def join("session:" <> session_id, _params, socket) do
    case SessionRegistry.fetch_worker(session_id) do
      {:ok, worker_pid} ->
        with {:ok, session} <- SessionRegistry.fetch(session_id) do
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

      {:error, :not_found} ->
        case SessionRegistry.fetch(session_id) do
          {:ok, %{status: status}} when status in [:stopped, :crashed] ->
            {:error,
             %{
               "reason" => "session_read_only",
               "session_id" => session_id,
               "status" => to_string(status)
             }}

          {:error, :not_found} ->
            {:error, %{"reason" => "session_not_found"}}

          {:ok, _session} ->
            {:error, %{"reason" => "session_not_found"}}
        end

      {:error, reason} ->
        {:error, %{"reason" => inspect(reason)}}
    end
  end

  @impl true
  def handle_in("submit", %{"text" => text} = payload, socket) do
    case normalize_submit_text(text) do
      {:ok, normalized_text} ->
        kind = payload |> Map.get("kind", "prompt") |> normalize_kind()

        case Surface.submit_message(socket.assigns.session_id, normalized_text, kind: kind) do
          {:ok, ack} ->
            {:reply, {:ok, %{"request_id" => ack.request_id}}, socket}

          {:error, _reason} ->
            {:reply, {:error, submit_error_payload(socket.assigns.session_id)}, socket}
        end

      {:error, :missing_text_field} ->
        {:reply, {:error, %{"reason" => "missing_text_field"}}, socket}
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

  defp normalize_submit_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :missing_text_field}
      _ -> {:ok, text}
    end
  end

  defp normalize_submit_text(_), do: {:error, :missing_text_field}

  defp join_payload(session_id, session) do
    %{
      "session_id" => session_id,
      "status" => session |> Map.get(:status) |> to_string(),
      "agent_name" => Map.get(session, :agent_name)
    }
  end

  defp submit_error_payload(session_id) do
    case SessionRegistry.fetch(session_id) do
      {:ok, %{status: status}} when status in [:stopped, :crashed] ->
        %{
          "reason" => "session_read_only",
          "session_id" => session_id,
          "status" => to_string(status)
        }

      _ ->
        %{
          "reason" => "session_unavailable",
          "session_id" => session_id
        }
    end
  end
end
