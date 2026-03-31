defmodule Prehen.Agents.Implementation do
  @moduledoc false

  @enforce_keys [:name, :command, :args, :wrapper]
  defstruct [:name, :command, :wrapper, args: [], env: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          wrapper: atom(),
          args: [String.t()],
          env: map()
        }
end
