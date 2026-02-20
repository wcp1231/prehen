defmodule Prehen.Agent.Orchestrator.Routers.Hybrid do
  @moduledoc false

  @behaviour Prehen.Agent.Orchestrator.Router

  alias Prehen.Agent.Orchestrator.Routers.{ModelBased, RuleBased}

  @impl true
  def select_worker(request, context) when is_map(request) and is_map(context) do
    case ModelBased.select_worker(request, context) do
      {:ok, worker_kind, meta} ->
        {:ok, worker_kind, %{meta | strategy: :hybrid}}

      {:error, _} ->
        {:ok, worker_kind, meta} = RuleBased.select_worker(request, context)
        {:ok, worker_kind, %{meta | strategy: :hybrid}}
    end
  end
end
