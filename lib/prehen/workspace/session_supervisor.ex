defmodule Prehen.Workspace.SessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec start_session(map(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(config, opts \\ []) when is_map(config) do
    name_opts = Keyword.take(opts, [:name])

    spec = %{
      id: Prehen.Agent.Session,
      start: {Prehen.Agent.Session, :start_link, [config, name_opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @spec stop_session(pid()) :: :ok | {:error, :not_found | :simple_one_for_one}
  def stop_session(session_pid) when is_pid(session_pid) do
    DynamicSupervisor.terminate_child(__MODULE__, session_pid)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
