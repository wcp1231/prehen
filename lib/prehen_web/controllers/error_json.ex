defmodule PrehenWeb.ErrorJSON do
  @moduledoc """
  统一 JSON 错误响应格式。
  """

  def render("404.json", _assigns) do
    %{error: %{type: "not_found", message: "Resource not found"}}
  end

  def render("400.json", _assigns) do
    %{error: %{type: "bad_request", message: "Bad request"}}
  end

  def render("422.json", %{reason: reason}) do
    %{error: %{type: "unprocessable_entity", message: inspect(reason)}}
  end

  def render("422.json", _assigns) do
    %{error: %{type: "unprocessable_entity", message: "Unprocessable entity"}}
  end

  def render("500.json", _assigns) do
    %{error: %{type: "internal_server_error", message: "Internal server error"}}
  end

  def render(template, _assigns) do
    %{error: %{type: "unknown", message: Phoenix.Controller.status_message_from_template(template)}}
  end
end
