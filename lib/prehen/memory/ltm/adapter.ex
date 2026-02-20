defmodule Prehen.Memory.LTM.Adapter do
  @moduledoc false

  @callback get(String.t(), map()) :: {:ok, map() | nil} | {:error, term()}
  @callback put(String.t(), map(), map()) :: :ok | {:error, term()}
end
