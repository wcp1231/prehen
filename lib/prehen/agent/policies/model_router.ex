defmodule Prehen.Agent.Policies.ModelRouter do
  @moduledoc false

  @spec select(map(), map()) :: String.t()
  def select(config, _context \\ %{}) do
    model = Map.get(config, :model, "openai:gpt-5-mini")
    if is_binary(model) and model != "", do: model, else: "openai:gpt-5-mini"
  end
end
