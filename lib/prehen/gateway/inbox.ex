defmodule Prehen.Gateway.Inbox do
  @moduledoc false

  alias Prehen.Client.Surface
  alias Prehen.Gateway.InboxProjection
  alias Prehen.Gateway.SessionRegistry

  def list_sessions, do: InboxProjection.list_sessions()

  def session_detail(session_id), do: InboxProjection.fetch_session(session_id)

  def history(session_id), do: InboxProjection.fetch_history(session_id)

  def create_session(opts), do: Surface.create_session(opts)

  def stop_session(session_id) do
    case InboxProjection.fetch_session(session_id) do
      {:ok, %{status: status}} when status in [:stopped, :crashed] ->
        :ok

      {:ok, _session} ->
        stop_live_session(session_id)

      {:error, :not_found} ->
        stop_live_session(session_id)
    end
  end

  defp stop_live_session(session_id) do
    case Surface.stop_session(session_id) do
      :ok ->
        ensure_retained_row(session_id)
        :ok

      {:error, %{type: :session_stop_failed, reason: :not_found}} ->
        {:error, %{type: :session_stop_failed, reason: :not_found}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp ensure_retained_row(session_id) do
    case InboxProjection.fetch_session(session_id) do
      {:ok, _row} ->
        :ok

      {:error, :not_found} ->
        case SessionRegistry.fetch(session_id) do
          {:ok, %{status: status} = session} when status in [:stopped, :crashed] ->
            :ok =
              InboxProjection.session_stopped(%{
                session_id: session_id,
                agent_name: Map.get(session, :agent_name),
                status: status
              })

            :ok

          _ ->
            :ok
        end
    end
  end
end
