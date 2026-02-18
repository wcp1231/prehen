defmodule Prehen.Agent.Policies.RetryPolicy do
  @moduledoc false

  @spec run((-> {:ok, term()} | {:error, term()}), keyword()) :: {:ok, term()} | {:error, term()}
  def run(fun, opts \\ []) when is_function(fun, 0) do
    attempts = max(Keyword.get(opts, :attempts, 1), 1)
    backoff_ms = max(Keyword.get(opts, :backoff_ms, 0), 0)

    do_run(fun, attempts, backoff_ms)
  end

  defp do_run(fun, attempts, backoff_ms) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, _} = error when attempts <= 1 ->
        error

      {:error, _} ->
        if backoff_ms > 0, do: Process.sleep(backoff_ms)
        do_run(fun, attempts - 1, backoff_ms)
    end
  end
end
