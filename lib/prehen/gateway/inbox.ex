defmodule Prehen.Gateway.Inbox do
  @moduledoc false

  alias Prehen.Client.Surface
  alias Prehen.Gateway.InboxProjection

  def list_sessions, do: InboxProjection.list_sessions()

  def session_detail(session_id), do: InboxProjection.fetch_session(session_id)

  def history(session_id), do: InboxProjection.fetch_history(session_id)

  def create_session(opts), do: Surface.create_session(opts)

  def stop_session(session_id), do: Surface.stop_session(session_id)
end
