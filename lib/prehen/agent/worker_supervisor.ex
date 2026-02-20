defmodule Prehen.Agent.WorkerSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias Prehen.Agent.Roles.Worker

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec start_worker(atom(), map(), map()) :: DynamicSupervisor.on_start_child()
  def start_worker(worker_kind, request, context)
      when is_atom(worker_kind) and is_map(request) and is_map(context) do
    spec = %{
      id: Worker,
      start: {Worker, :start_link, [worker_kind, request, context]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
