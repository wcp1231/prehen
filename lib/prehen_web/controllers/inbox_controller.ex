defmodule PrehenWeb.InboxController do
  use Phoenix.Controller, formats: [:json]

  alias Prehen.Gateway.Inbox

  action_fallback(PrehenWeb.FallbackController)

  def index(conn, _params) do
    json(conn, %{sessions: Inbox.list_sessions()})
  end

  def create(conn, params) do
    with {:ok, %{session_id: session_id, agent: agent}} <-
           Inbox.create_session(build_session_opts(params)),
         {:ok, detail} <- Inbox.session_detail(session_id) do
      conn
      |> put_status(:created)
      |> json(%{
        session_id: session_id,
        agent: agent,
        status: detail.status |> to_string()
      })
    end
  end

  def show(conn, %{"id" => session_id}) do
    with {:ok, session} <- Inbox.session_detail(session_id) do
      json(conn, %{session: session})
    end
  end

  def history(conn, %{"id" => session_id}) do
    with {:ok, history} <- Inbox.history(session_id) do
      json(conn, %{history: history})
    end
  end

  def delete(conn, %{"id" => session_id}) do
    with :ok <- Inbox.stop_session(session_id) do
      send_resp(conn, :no_content, "")
    end
  end

  defp build_session_opts(params) do
    []
    |> put_optional(params, "agent", :agent)
    |> put_optional(params, "provider", :provider)
    |> put_optional(params, "model", :model)
    |> put_optional(params, "workspace", :workspace)
  end

  defp put_optional(opts, params, key, opt_key) do
    case Map.get(params, key) do
      nil -> opts
      value -> Keyword.put(opts, opt_key, value)
    end
  end
end
