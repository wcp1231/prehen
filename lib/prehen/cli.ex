defmodule Prehen.CLI do
  @moduledoc false

  @usage """
  Usage:
    prehen run "<task>" [--session-id ID] [--max-steps N] [--timeout-ms N] [--root-dir PATH] [--model NAME] [--trace-json]
  """

  @spec main([String.t()]) :: {:ok, map()} | {:error, term()}
  def main(argv) do
    {opts, args, _invalid} =
      OptionParser.parse(argv,
        strict: [
          session_id: :string,
          max_steps: :integer,
          timeout_ms: :integer,
          root_dir: :string,
          model: :string,
          trace_json: :boolean
        ]
      )

    case args do
      ["run" | task_parts] when task_parts != [] ->
        task = Enum.join(task_parts, " ")
        run_task(task, opts)

      _ ->
        IO.puts(:stderr, String.trim(@usage))
        {:error, :invalid_args}
    end
  end

  defp run_task(task, opts) do
    case Prehen.Client.Surface.run(task, opts) do
      {:ok, result} ->
        print_result(result, opts)
        {:ok, result}

      {:error, result} ->
        print_error(result, opts)
        {:error, result}
    end
  end

  defp print_result(result, opts) do
    if Keyword.get(opts, :trace_json, false) do
      IO.puts("Trace:")
      IO.puts(Jason.encode!(result.trace))
    end

    IO.puts("Answer:")
    IO.puts(result.answer)
  end

  defp print_error(result, opts) when is_map(result) do
    if Keyword.get(opts, :trace_json, false) do
      IO.puts("Trace:")
      IO.puts(Jason.encode!(Map.get(result, :trace, [])))
    end

    IO.puts(:stderr, "Execution failed: #{inspect(Map.get(result, :reason, :unknown))}")
    IO.puts(:stderr, Map.get(result, :answer, ""))
  end

  defp print_error(reason, _opts) do
    IO.puts(:stderr, "Execution failed: #{inspect(reason)}")
  end
end
