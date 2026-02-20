defmodule Prehen.Agent.Orchestrator.Router do
  @moduledoc false

  @callback select_worker(map(), map()) ::
              {:ok, atom(), %{strategy: atom(), reason: String.t()}} | {:error, term()}
end
