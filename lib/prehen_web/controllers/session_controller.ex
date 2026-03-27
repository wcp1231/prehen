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

    case normalize_message_text(text) do
      {:ok, normalized_text} ->
        with {:ok, submit} <- Surface.submit_message(session_id, normalized_text, kind: :prompt) do
          conn
          |> put_status(:accepted)
          |> json(submit)
        end

      {:error, :bad_request} ->
        conn
        |> put_status(:bad_request)
        |> put_view(json: PrehenWeb.ErrorJSON)
        |> render("400.json")
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

  defp normalize_message_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :bad_request}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_message_text(_), do: {:error, :bad_request}
end
