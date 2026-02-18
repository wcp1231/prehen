defmodule Prehen.Agent.EventBridge do
  @moduledoc false

  @spec project(String.t(), map(), keyword()) :: map()
  def project(type, payload, opts \\ []) when is_binary(type) and is_map(payload) do
    source = Keyword.get(opts, :source, "prehen.session")

    %{
      type: type,
      at_ms: System.system_time(:millisecond),
      source: source
    }
    |> Map.merge(payload)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
