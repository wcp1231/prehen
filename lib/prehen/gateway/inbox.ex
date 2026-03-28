defmodule Prehen.Gateway.Inbox do
  @moduledoc false

  alias Prehen.Client.Surface
  alias Prehen.Gateway.InboxProjection

  def list_sessions, do: InboxProjection.list_sessions()

  def session_detail(session_id), do: InboxProjection.fetch_session(session_id)

  def history(session_id), do: InboxProjection.fetch_history(session_id)

  def create_session(opts), do: Surface.create_session(opts)

  def stop_session(session_id) do
    case InboxProjection.fetch_session(session_id) do
      {:ok, %{status: status}} when status in [:stopped, :crashed] ->
        :ok

      {:ok, _session} ->
        case Surface.stop_session(session_id) do
          :ok -> :ok
          {:error, error} -> {:error, error}
        end

      {:error, :not_found} ->
        {:error, %{type: :session_stop_failed, reason: :not_found}}
    end
  end
end
