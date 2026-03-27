defmodule Prehen.Agents.Profile do
  @moduledoc false

  @enforce_keys [:name, :command]
  defstruct [:name, :command, args: [], env: %{}, transport: :stdio, metadata: %{}]
end
