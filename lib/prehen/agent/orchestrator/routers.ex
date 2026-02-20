defmodule Prehen.Agent.Orchestrator.Routers do
  @moduledoc false

  alias Prehen.Agent.Orchestrator.Routers.{Hybrid, ModelBased, RuleBased}

  @type routing_mode :: :rule | :model | :hybrid
  @type router_module :: module()

  @spec by_mode(routing_mode()) :: router_module()
  def by_mode(:rule), do: RuleBased
  def by_mode(:model), do: ModelBased
  def by_mode(:hybrid), do: Hybrid
end
