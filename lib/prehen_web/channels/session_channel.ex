defmodule PrehenWeb.SessionChannel do
  use Phoenix.Channel

  alias Prehen.Client.Surface
  alias Prehen.Gateway.SessionRegistry
  alias PrehenWeb.EventSerializer

  @impl true
  def join("session:" <> session_id, _params, socket) do
    case SessionRegistry.fetch(session_id) do
      {:ok, _session} ->
        :ok = Phoenix.PubSub.subscribe(Prehen.PubSub, "session:#{session_id}")
        {:ok, %{"session_id" => session_id}, assign(socket, :session_id, session_id)}

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
        {:reply, {:error, %{"reason" => "session_unavailable"}}, socket}
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

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, _socket), do: :ok

  defp normalize_kind("prompt"), do: :prompt
  defp normalize_kind("steering"), do: :steering
  defp normalize_kind("steer"), do: :steering
  defp normalize_kind("follow_up"), do: :follow_up
  defp normalize_kind(_), do: :prompt
end
