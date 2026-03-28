defmodule Mix.Tasks.Prehen.Server do
  use Mix.Task

  @shortdoc "Start the Prehen gateway server"

  @moduledoc """
  Starts the Prehen OTP application and keeps the VM alive so the HTTP,
  Phoenix Channel, and inbox surfaces stay available for local use.
  """

  @impl Mix.Task
  def run(args) do
    run(args,
      start_task: &Mix.Task.run/2,
      announce: fn message -> Mix.shell().info(message) end,
      wait: &wait_forever/0
    )
  end

  def run([], opts) when is_list(opts) do
    start_task = Keyword.fetch!(opts, :start_task)
    announce = Keyword.fetch!(opts, :announce)
    wait = Keyword.fetch!(opts, :wait)

    :ok = start_task.("app.start", [])
    _ = announce.("Prehen server listening on #{inbox_url()}")
    wait.()
  end

  def run(_args, _opts) do
    Mix.raise("mix prehen.server does not accept arguments")
  end

  defp wait_forever do
    Process.sleep(:infinity)
  end

  defp inbox_url do
    endpoint_config = Application.get_env(:prehen, PrehenWeb.Endpoint, [])
    url_config = Keyword.get(endpoint_config, :url, [])
    http_config = Keyword.get(endpoint_config, :http, [])

    host = Keyword.get(url_config, :host, "localhost")
    port = Keyword.get(http_config, :port, 4000)

    "http://#{host}:#{port}/inbox"
  end
end
