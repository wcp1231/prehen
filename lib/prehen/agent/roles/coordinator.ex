defmodule Prehen.Agent.Roles.Coordinator do
  @moduledoc false

  use GenServer

  alias Prehen.Agent.Orchestrator

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec submit(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def submit(request, opts \\ []) when is_map(request) and is_list(opts) do
    context = Map.new(opts)
    GenServer.call(__MODULE__, {:submit, request, context}, 10_000)
  end

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def handle_call({:submit, request, context}, _from, state) do
    parent_call_id = Map.get(context, :parent_call_id, gen_id("coord"))
    context = Map.put(context, :parent_call_id, parent_call_id)

    reply =
      case Orchestrator.dispatch(request, context) do
        {:ok, result} ->
          {:ok,
           result
           |> Map.put(:orchestrator_agent_id, Map.get(result, :agent_id))
           |> Map.put(:agent_id, "coordinator")
           |> Map.put(:parent_call_id, parent_call_id)}

        {:error, reason} ->
          {:ok,
           %{
             status: :degraded,
             reason: reason,
             request: request,
             strategy: :coordinator_fallback,
             agent_id: "coordinator",
             parent_call_id: parent_call_id
           }}
      end

    {:reply, reply, state}
  end

  defp gen_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end
