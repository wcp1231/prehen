defmodule PrehenWeb.SessionController do
  use Phoenix.Controller, formats: [:json]

  alias Prehen.Client.Surface
  alias PrehenWeb.EventSerializer

  action_fallback PrehenWeb.FallbackController

  def create(conn, params) do
    opts = build_session_opts(params)

    with {:ok, session} <- Surface.create_session(opts) do
      conn
      |> put_status(:created)
      |> json(%{session_id: session.session_id})
    end
  end

  def index(conn, _params) do
    sessions =
      Surface.list_sessions()
      |> Enum.map(fn record ->
        %{
          session_id: record.session_id,
          status: record.status,
          inserted_at_ms: record.inserted_at_ms
        }
      end)

    json(conn, %{sessions: sessions})
  end

  def show(conn, %{"id" => session_id}) do
    with {:ok, %{session_pid: pid}} <- Surface.resume_session(session_id),
         {:ok, status} <- Surface.session_status(pid) do
      serialized =
        status
        |> Map.drop([:pid])
        |> EventSerializer.serialize()

      json(conn, %{session: serialized})
    else
      {:error, %{code: :session_resume_failed}} ->
        conn |> put_status(:not_found) |> put_view(json: PrehenWeb.ErrorJSON) |> render("404.json")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> put_view(json: PrehenWeb.ErrorJSON) |> render("404.json")

      {:error, _reason} = error ->
        error
    end
  end

  def delete(conn, %{"id" => session_id}) do
    with {:ok, %{session_pid: pid}} <- Surface.resume_session(session_id),
         :ok <- Surface.stop_session(pid) do
      send_resp(conn, :no_content, "")
    else
      {:error, %{code: :session_resume_failed}} ->
        conn |> put_status(:not_found) |> put_view(json: PrehenWeb.ErrorJSON) |> render("404.json")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> put_view(json: PrehenWeb.ErrorJSON) |> render("404.json")

      {:error, _reason} = error ->
        error
    end
  end

  def replay(conn, %{"id" => session_id}) do
    events =
      Surface.replay_session(session_id)
      |> Enum.map(&EventSerializer.serialize/1)

    json(conn, %{events: events})
  end

  defp build_session_opts(params) do
    opts = []

    opts =
      case Map.get(params, "agent") do
        nil -> opts
        agent -> Keyword.put(opts, :agent, agent)
      end

    opts
  end
end
