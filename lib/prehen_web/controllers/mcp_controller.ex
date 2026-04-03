defmodule PrehenWeb.MCPController do
  use Phoenix.Controller, formats: [:json]

  alias Prehen.Home
  alias Prehen.MCP.SessionAuth
  alias Prehen.MCP.ToolDispatch

  def handle(conn, params) do
    request_id = Map.get(params, "id")

    with {:ok, token} <- bearer_token(conn),
         :ok <- ensure_local_request(conn),
         {:ok, auth_context} <- auth_context(token),
         {:ok, result} <- ToolDispatch.call(Map.put_new(auth_context, :prehen_home, Home.root()), params) do
      json(conn, %{"jsonrpc" => "2.0", "id" => request_id, "result" => result})
    else
      {:error, :local_only} ->
        conn
        |> put_status(:forbidden)
        |> json(error_response(request_id, -32003, "local_only"))

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> json(error_response(request_id, -32001, "unauthorized"))

      {:error, :method_not_found} ->
        json(conn, error_response(request_id, -32601, "method_not_found"))

      {:error, :not_found} ->
        json(conn, error_response(request_id, -32004, "not_found"))
    end
  end

  defp ensure_local_request(%Plug.Conn{remote_ip: remote_ip}) do
    if local_ip?(remote_ip), do: :ok, else: {:error, :local_only}
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, :unauthorized}
    end
  end

  defp auth_context(token) do
    case SessionAuth.lookup(token) do
      {:ok, context} -> {:ok, context}
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  defp error_response(id, code, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }
  end

  defp local_ip?({127, 0, 0, 1}), do: true
  defp local_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp local_ip?(_remote_ip), do: false
end
