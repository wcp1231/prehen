defmodule PrehenWeb.FallbackController do
  use Phoenix.Controller, formats: [:json]

  def call(conn, {:error, %{type: :session_create_failed} = error}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PrehenWeb.ErrorJSON)
    |> render("422.json", reason: error.reason)
  end

  def call(conn, {:error, %{type: type} = error})
      when type in [:session_status_failed, :session_stop_failed] do
    conn
    |> put_status(:not_found)
    |> put_view(json: PrehenWeb.ErrorJSON)
    |> render("404.json", reason: error.reason)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: PrehenWeb.ErrorJSON)
    |> render("404.json")
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PrehenWeb.ErrorJSON)
    |> render("422.json", reason: reason)
  end
end
