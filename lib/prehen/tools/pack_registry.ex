defmodule Prehen.Tools.PackRegistry do
  @moduledoc """
  Capability pack 注册中心。

  中文：
  - 管理工具能力包与 pack->tools 映射。
  - 为 workspace/session 提供 pack 校验与工具解析。
  - 当前内置 `local_fs` 作为默认 pack。

  English:
  - Registry for capability packs and pack->tool mappings.
  - Validates packs and resolves tool modules for workspace/session setup.
  - Ships with built-in `local_fs` as the default pack.
  """

  use GenServer

  @default_packs [Prehen.Tools.Packs.LocalFS]

  @type pack_name :: atom()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec register_pack(module()) :: :ok | {:error, term()}
  def register_pack(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :name, 0) and
         function_exported?(module, :tools, 0) do
      register(module.name(), module.tools())
    else
      {:error, :invalid_pack_module}
    end
  end

  @spec register(pack_name(), [module()]) :: :ok | {:error, term()}
  def register(name, tools) when is_atom(name) and is_list(tools) do
    GenServer.call(__MODULE__, {:register, name, tools})
  end

  @spec list_packs() :: %{optional(pack_name()) => [module()]}
  def list_packs do
    GenServer.call(__MODULE__, :list_packs)
  end

  @spec resolve_tools([pack_name()]) :: {:ok, [module()]} | {:error, term()}
  def resolve_tools(pack_names) when is_list(pack_names) do
    GenServer.call(__MODULE__, {:resolve_tools, pack_names})
  end

  @impl true
  def init(_state) do
    state =
      Enum.reduce(@default_packs, %{}, fn module, acc ->
        if Code.ensure_loaded?(module) and function_exported?(module, :name, 0) and
             function_exported?(module, :tools, 0) do
          Map.put(acc, module.name(), Enum.filter(module.tools(), &is_atom/1))
        else
          acc
        end
      end)

    {:ok, state}
  end

  @impl true
  def handle_call({:register, name, tools}, _from, state) do
    normalized_tools = tools |> Enum.filter(&is_atom/1) |> Enum.uniq()

    if normalized_tools == [] do
      {:reply, {:error, :empty_pack_tools}, state}
    else
      {:reply, :ok, Map.put(state, name, normalized_tools)}
    end
  end

  def handle_call(:list_packs, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:resolve_tools, pack_names}, _from, state) do
    normalized = Enum.filter(pack_names, &is_atom/1)

    with :ok <- ensure_known_packs(state, normalized) do
      tools =
        normalized
        |> Enum.flat_map(&Map.get(state, &1, []))
        |> Enum.uniq()

      {:reply, {:ok, tools}, state}
    else
      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp ensure_known_packs(_state, []), do: :ok

  defp ensure_known_packs(state, [pack | rest]) do
    if Map.has_key?(state, pack) do
      ensure_known_packs(state, rest)
    else
      {:error, {:capability_pack_not_found, pack}}
    end
  end
end
