defmodule Prehen.Agent.JidoRuntimeStarter do
  @moduledoc false

  use GenServer

  @jido_instance Prehen.JidoRuntime

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec health() :: map()
  def health do
    if Process.whereis(@jido_instance) do
      %{status: :up}
    else
      %{status: :down}
    end
  end

  @impl true
  def init(state) do
    with {:ok, _apps} <- Application.ensure_all_started(:jido_ai),
         :ok <- ensure_runtime_started() do
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:jido_runtime_start_failed, reason}}
    end
  end

  defp ensure_runtime_started do
    case Jido.start(name: @jido_instance) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
