defmodule Prehen.CLI do
  @moduledoc false

  @usage """
  Usage:
    prehen run --agent NAME "<task>" [--workspace PATH] [--session-id ID] [--max-steps N] [--timeout-ms N] [--trace-json]
  """

  @spec main([String.t()]) :: {:ok, map()} | {:error, term()}
  def main(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          workspace: :string,
          session_id: :string,
          agent: :string,
          max_steps: :integer,
          timeout_ms: :integer,
          trace_json: :boolean
        ]
      )

    cond do
      invalid != [] ->
        print_invalid_switches(invalid)
        {:error, :invalid_args}

      true ->
        case args do
          ["run" | task_parts] when task_parts != [] ->
            task = Enum.join(task_parts, " ")
            run_task(task, opts)

          _ ->
            IO.puts(:stderr, String.trim(@usage))
            {:error, :invalid_args}
        end
    end
  end

  defp print_invalid_switches(invalid) when is_list(invalid) do
    Enum.each(invalid, fn
      {switch, _value} ->
        normalized =
          switch
          |> to_string()
          |> String.trim_leading("-")
          |> String.replace("_", "-")

        cond do
          normalized == "root-dir" ->
            IO.puts(
              :stderr,
              "Invalid option: --root-dir (removed). Use --workspace PATH instead."
            )

          normalized == "model" ->
            IO.puts(:stderr, "Invalid option: --model (removed). Use --agent NAME.")

          true ->
            IO.puts(:stderr, "Invalid option: --#{normalized}")
        end

      other ->
        IO.puts(:stderr, "Invalid option: #{inspect(other)}")
    end)

    if Enum.any?(invalid) do
      IO.puts(:stderr, String.trim(@usage))
    end
  end

  defp run_task(task, opts) do
    opts =
      case normalize_agent(Keyword.get(opts, :agent)) do
        nil -> Keyword.delete(opts, :agent)
        agent -> Keyword.put(opts, :agent, agent)
      end

    case Prehen.Client.Surface.run(task, opts) do
      {:ok, result} ->
        print_result(result, opts)
        {:ok, result}

      {:error, result} ->
        print_error(result, opts)
        {:error, result}
    end
  end

  defp normalize_agent(agent) when is_binary(agent) do
    case String.trim(agent) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_agent(_), do: nil

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
