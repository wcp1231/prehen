defmodule Prehen.Agent.Session.Adapter do
  @moduledoc false

  @callback start_agent(map()) :: {:ok, term()} | {:error, term()}
  @callback stop_agent(term()) :: :ok
  @callback ask(term(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback await(term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback cancel(term(), keyword()) :: :ok | {:error, term()}
  @callback steer(term(), keyword()) :: :ok | {:error, term()}
  @callback follow_up(term(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback status(term()) :: {:ok, term()} | {:error, term()}
end
