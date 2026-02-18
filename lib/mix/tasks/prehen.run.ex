defmodule Mix.Tasks.Prehen.Run do
  use Mix.Task

  @shortdoc "Run Prehen agent from Mix"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case Prehen.CLI.main(["run" | args]) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("prehen run failed: #{inspect(reason)}")
    end
  end
end
