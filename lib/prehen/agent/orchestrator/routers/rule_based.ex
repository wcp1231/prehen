defmodule Prehen.Agent.Orchestrator.Routers.RuleBased do
  @moduledoc false

  @behaviour Prehen.Agent.Orchestrator.Router

  @impl true
  def select_worker(request, _context) when is_map(request) do
    query = Map.get(request, :query, Map.get(request, "query", ""))

    if is_binary(query) and coding_query?(query) do
      {:ok, :coding_worker, %{strategy: :rule, reason: "query contains coding keywords"}}
    else
      {:ok, :general_worker, %{strategy: :rule, reason: "default general routing"}}
    end
  end

  defp coding_query?(query) do
    downcased = String.downcase(query)

    Enum.any?(["code", "bug", "fix", "refactor", "test", "elixir", "function"], fn token ->
      String.contains?(downcased, token)
    end)
  end
end
