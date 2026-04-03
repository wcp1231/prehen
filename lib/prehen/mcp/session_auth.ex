defmodule Prehen.MCP.SessionAuth do
  @moduledoc false

  use GenServer

  alias Prehen.Gateway.SessionRegistry
  alias Prehen.Gateway.SessionWorker

  @default_capabilities ["skills.search", "skills.load"]

  @type context :: %{
          session_id: String.t(),
          profile_id: String.t(),
          capabilities: [String.t()]
        }

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  @spec issue(String.t(), String.t(), keyword()) :: {:ok, String.t()}
  def issue(session_id, profile_id, opts \\ [])
      when is_binary(session_id) and session_id != "" and is_binary(profile_id) and profile_id != "" do
    capabilities =
      opts
      |> Keyword.get(:capabilities, @default_capabilities)
      |> normalize_capabilities()

    GenServer.call(__MODULE__, {:issue, session_id, profile_id, capabilities})
  end

  @spec lookup(String.t()) :: {:ok, context()} | {:error, :not_found}
  def lookup(token) when is_binary(token) and token != "" do
    GenServer.call(__MODULE__, {:lookup, token})
  end

  def lookup(_token), do: {:error, :not_found}

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(token) when is_binary(token) and token != "" do
    GenServer.call(__MODULE__, {:invalidate, token})
  end

  def invalidate(_token), do: :ok

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:issue, session_id, profile_id, capabilities}, _from, state) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    context = %{session_id: session_id, profile_id: profile_id, capabilities: capabilities}

    {:reply, {:ok, token}, Map.put(state, token, context)}
  end

  def handle_call({:lookup, token}, _from, state) do
    case Map.fetch(state, token) do
      {:ok, context} ->
        {:reply, {:ok, context}, state}

      :error ->
        case recover_context(token) do
          {:ok, context} ->
            {:reply, {:ok, context}, Map.put(state, token, context)}

          {:error, :not_found} ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  def handle_call({:invalidate, token}, _from, state) do
    {:reply, :ok, Map.delete(state, token)}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{}}
  end

  defp normalize_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_capabilities(_capabilities), do: @default_capabilities

  defp recover_context(token) do
    case Process.whereis(SessionRegistry) do
      nil ->
        {:error, :not_found}

      _pid ->
        SessionRegistry.list_workers()
        |> Enum.find_value({:error, :not_found}, fn worker ->
          case SessionWorker.mcp_context(worker) do
            {:ok, %{token: ^token, context: context}} -> {:ok, context}
            _ -> nil
          end
        end)
    end
  catch
    :exit, _reason ->
      {:error, :not_found}
  end
end
