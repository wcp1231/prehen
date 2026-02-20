defmodule Prehen.Agent.Orchestrator.Routers.ModelBased do
  @moduledoc false

  @behaviour Prehen.Agent.Orchestrator.Router

  @impl true
  def select_worker(request, context) when is_map(request) and is_map(context) do
    hint =
      Map.get(context, :model_hint) ||
        Map.get(request, :model_hint) ||
        Map.get(request, "model_hint")

    case hint do
      :coding ->
        {:ok, :coding_worker, %{strategy: :model, reason: "model hint resolved to coding"}}

      :general ->
        {:ok, :general_worker, %{strategy: :model, reason: "model hint resolved to general"}}

      "coding" ->
        {:ok, :coding_worker, %{strategy: :model, reason: "model hint resolved to coding"}}

      "general" ->
        {:ok, :general_worker, %{strategy: :model, reason: "model hint resolved to general"}}

      _ ->
        {:error, :model_route_not_available}
    end
  end
end
