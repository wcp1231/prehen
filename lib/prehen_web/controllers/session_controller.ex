defmodule PrehenWeb.SessionController do
  use Phoenix.Controller, formats: [:json]

  alias Prehen.Client.Surface

  action_fallback PrehenWeb.FallbackController

  def create(conn, params) do
    opts = build_session_opts(params)

    with {:ok, session} <- Surface.create_session(opts) do
      conn
      |> put_status(:created)
      |> json(session)
    end
  end

  def show(conn, %{"id" => session_id}) do
    with {:ok, status} <- Surface.session_status(session_id), do: json(conn, %{session: status})
  end

  def delete(conn, %{"id" => session_id}) do
    with :ok <- Surface.stop_session(session_id) do
      send_resp(conn, :no_content, "")
    end
  end

  def create_message(conn, %{"id" => session_id} = params) do
    text = Map.get(params, "text") || Map.get(params, "message")

    with {:ok, submit} <- Surface.submit_message(session_id, text, kind: :prompt) do
      conn
      |> put_status(:accepted)
      |> json(submit)
    end
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
