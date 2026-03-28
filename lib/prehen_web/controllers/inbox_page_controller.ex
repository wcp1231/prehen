defmodule PrehenWeb.InboxPageController do
  use Phoenix.Controller, formats: [:html]

  alias PrehenWeb.InboxPage

  def show(conn, _params) do
    html(conn, InboxPage.render())
  end
end
