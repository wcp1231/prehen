defmodule Prehen.Agent.EventBridge do
  @moduledoc false

  @schema_version 2

  @spec project(String.t(), map(), keyword()) :: map()
  def project(type, payload, opts \\ []) when is_binary(type) and is_map(payload) do
    source = Keyword.get(opts, :source, "prehen.session")
    schema_version = Keyword.get(opts, :schema_version, @schema_version)

    %{
      type: type,
      at_ms: System.system_time(:millisecond),
      source: source,
      schema_version: schema_version
    }
    |> Map.merge(payload)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
