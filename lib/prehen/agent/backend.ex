defmodule Prehen.Agent.Backend do
  @moduledoc false

  @callback run(String.t(), map()) :: {:ok, map()} | {:error, map()}
end
