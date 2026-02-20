defmodule Prehen.Workspace.SessionManager do
  @moduledoc """
  Workspace 控制面（control plane）管理器。

  中文：
  - 管理 session 的创建/索引/停止与生命周期元数据。
  - 不保存执行面细节（执行状态由 Session 进程持有）。
  - 负责空闲检测回收、workspace 级 capability 配置与校验。

  English:
  - Control-plane manager for workspace sessions.
  - Owns session creation/indexing/stopping and lifecycle metadata.
  - Does not hold execution-plane state (that belongs to Session processes).
  - Handles idle reclamation and workspace-level capability validation.
  """

  use GenServer

  require Logger

  alias Prehen.Agent.Session
  alias Prehen.Tools.PackRegistry
  alias Prehen.Workspace.{SessionLifecycle, SessionSupervisor}

  @default_workspace "default"
  @default_sync_interval_ms 100
  @default_idle_ttl_ms 300_000

  @type lifecycle :: SessionLifecycle.t()
  @type session_record :: %{
          session_id: String.t(),
          workspace_id: String.t(),
          pid: pid(),
          inserted_at_ms: integer(),
          status: atom(),
          lifecycle: lifecycle(),
          last_active_at_ms: integer(),
          idle_since_at_ms: integer() | nil,
          last_snapshot_at_ms: integer(),
          idle_ttl_ms: non_neg_integer(),
          capability_packs: [atom()],
          capability_allowlist: [atom()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec start_session(map(), keyword()) ::
          {:ok, %{pid: pid(), session_id: String.t(), workspace_id: String.t()}}
          | {:error, term()}
  def start_session(config, opts \\ []) when is_map(config) do
    GenServer.call(__MODULE__, {:start_session, config, opts})
  end

  @spec resume_session(String.t(), map(), keyword()) ::
          {:ok, %{pid: pid(), session_id: String.t(), workspace_id: String.t()}}
          | {:error, term()}
  def resume_session(session_id, config, opts \\ [])
      when is_binary(session_id) and is_map(config) do
    GenServer.call(__MODULE__, {:resume_session, session_id, config, opts})
  end

  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  def stop_session(session_pid) when is_pid(session_pid) do
    GenServer.call(__MODULE__, {:stop_session, session_pid})
  end

  @spec list_sessions(String.t() | nil) :: [session_record()]
  def list_sessions(workspace_id \\ nil) do
    GenServer.call(__MODULE__, {:list_sessions, workspace_id})
  end

  @spec get_session(pid()) :: {:ok, session_record()} | {:error, :not_found}
  def get_session(session_pid) when is_pid(session_pid) do
    GenServer.call(__MODULE__, {:get_session, session_pid})
  end

  @spec get_session_by_id(String.t()) :: {:ok, session_record()} | {:error, :not_found}
  def get_session_by_id(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:get_session_by_id, session_id})
  end

  @spec set_workspace_capability_packs(String.t(), [atom()]) :: :ok | {:error, term()}
  def set_workspace_capability_packs(workspace_id, packs)
      when is_binary(workspace_id) and is_list(packs) do
    GenServer.call(__MODULE__, {:set_workspace_capability_packs, workspace_id, packs})
  end

  @spec health() :: map()
  def health do
    if Process.whereis(__MODULE__) do
      %{status: :up, sessions: length(list_sessions())}
    else
      %{status: :down}
    end
  end

  @impl true
  def init(_arg) do
    sync_interval_ms =
      Application.get_env(:prehen, :session_sync_interval_ms, @default_sync_interval_ms)

    state = %{
      sessions: %{},
      monitors: %{},
      sync_interval_ms: sync_interval_ms,
      workspace_capability_packs: %{}
    }

    {:ok, schedule_sync(state)}
  end

  @impl true
  def handle_call({:start_session, config, opts}, _from, state) do
    workspace_id = opts |> Keyword.get(:workspace_id, @default_workspace) |> to_string()

    case start_managed_session(state, config, workspace_id, opts) do
      {:ok, reply, next_state} -> {:reply, {:ok, reply}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:resume_session, session_id, config, opts}, _from, state) do
    workspace_id = opts |> Keyword.get(:workspace_id, @default_workspace) |> to_string()

    case find_session_record_by_id(state.sessions, session_id) do
      {:ok, record} ->
        reply = %{
          pid: record.pid,
          session_id: record.session_id,
          workspace_id: record.workspace_id,
          capability_packs: record.capability_packs
        }

        {:reply, {:ok, reply}, state}

      :error ->
        session_config =
          config
          |> Map.put(:session_id, session_id)
          |> Map.put(:resume, true)

        case start_managed_session(state, session_config, workspace_id, opts) do
          {:ok, reply, next_state} -> {:reply, {:ok, reply}, next_state}
          {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
        end
    end
  end

  def handle_call({:stop_session, session_pid}, _from, state) do
    case Map.fetch(state.sessions, session_pid) do
      {:ok, record} ->
        state = put_in(state, [:sessions, session_pid], %{record | lifecycle: :stopping})
        _ = SessionSupervisor.stop_session(session_pid)
        {:reply, :ok, prune_session(state, session_pid)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:list_sessions, workspace_id}, _from, state) do
    sessions =
      state.sessions
      |> Map.values()
      |> Enum.filter(fn record ->
        is_nil(workspace_id) or record.workspace_id == workspace_id
      end)
      |> Enum.sort_by(& &1.inserted_at_ms)

    {:reply, sessions, state}
  end

  def handle_call({:get_session, session_pid}, _from, state) do
    case Map.fetch(state.sessions, session_pid) do
      {:ok, record} -> {:reply, {:ok, record}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_session_by_id, session_id}, _from, state) do
    case find_session_record_by_id(state.sessions, session_id) do
      {:ok, record} -> {:reply, {:ok, record}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:set_workspace_capability_packs, workspace_id, packs}, _from, state) do
    normalized = normalize_pack_list(packs)

    with {:ok, _tools} <- PackRegistry.resolve_tools(normalized) do
      next =
        put_in(state, [:workspace_capability_packs, workspace_id], normalized)

      {:reply, :ok, next}
    else
      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, session_pid} ->
        {:noreply, prune_session(state, session_pid)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:sync_sessions, state) do
    next_state =
      state.sessions
      |> Map.keys()
      |> Enum.reduce(state, fn session_pid, acc ->
        sync_session(acc, session_pid)
      end)
      |> schedule_sync()

    {:noreply, next_state}
  end

  defp prune_session(state, session_pid) do
    {monitor_ref, monitors} =
      Enum.reduce(state.monitors, {nil, state.monitors}, fn {ref, pid}, {found, acc} ->
        if pid == session_pid do
          {ref, Map.delete(acc, ref)}
        else
          {found, acc}
        end
      end)

    if is_reference(monitor_ref), do: Process.demonitor(monitor_ref, [:flush])

    %{state | sessions: Map.delete(state.sessions, session_pid), monitors: monitors}
  end

  defp sync_session(state, session_pid) do
    case Map.fetch(state.sessions, session_pid) do
      :error ->
        state

      {:ok, record} ->
        with true <- Process.alive?(session_pid),
             {:ok, snapshot} <- safe_snapshot(session_pid) do
          now = System.system_time(:millisecond)
          queue_empty? = queue_empty?(snapshot)
          lifecycle = SessionLifecycle.evolve(record.lifecycle, snapshot.status, queue_empty?)

          last_active_at_ms =
            if snapshot.status == :running or not queue_empty? do
              now
            else
              record.last_active_at_ms
            end

          idle_since_at_ms =
            if lifecycle == :idle do
              record.idle_since_at_ms || now
            else
              nil
            end

          updated_record = %{
            record
            | status: snapshot.status,
              lifecycle: lifecycle,
              last_active_at_ms: last_active_at_ms,
              idle_since_at_ms: idle_since_at_ms,
              last_snapshot_at_ms: now
          }

          if should_reclaim?(updated_record, now) do
            Logger.debug("reclaiming idle session=#{updated_record.session_id}")
            _ = SessionSupervisor.stop_session(session_pid)
            prune_session(state, session_pid)
          else
            put_in(state, [:sessions, session_pid], updated_record)
          end
        else
          _ ->
            prune_session(state, session_pid)
        end
    end
  end

  defp should_reclaim?(record, now_ms) do
    is_integer(record.idle_since_at_ms) and record.lifecycle == :idle and
      now_ms - record.idle_since_at_ms >= record.idle_ttl_ms
  end

  defp queue_empty?(snapshot) when is_map(snapshot) do
    sizes = Map.get(snapshot, :queue_sizes, %{})
    active = Map.get(snapshot, :active)

    active == nil and Map.get(sizes, :prompt, 0) == 0 and Map.get(sizes, :steering, 0) == 0 and
      Map.get(sizes, :follow_up, 0) == 0
  end

  defp queue_empty?(_), do: true

  defp safe_snapshot(session_pid) when is_pid(session_pid) do
    {:ok, Session.snapshot(session_pid)}
  catch
    :exit, _ -> {:error, :session_unavailable}
  end

  defp idle_ttl_ms(config, opts) do
    ttl =
      Keyword.get(opts, :session_idle_ttl_ms) ||
        Map.get(config, :session_idle_ttl_ms, @default_idle_ttl_ms)

    cond do
      is_integer(ttl) and ttl > 0 -> ttl
      true -> @default_idle_ttl_ms
    end
  end

  defp start_managed_session(state, config, workspace_id, opts) do
    start_opts = Keyword.take(opts, [:name])
    now = System.system_time(:millisecond)

    with {:ok, session_config, capability_packs, capability_allowlist} <-
           resolve_session_capabilities(state, config, workspace_id, opts),
         {:ok, session_pid} <- SessionSupervisor.start_session(session_config, start_opts),
         snapshot <- Session.snapshot(session_pid),
         true <- is_binary(snapshot.session_id) do
      ref = Process.monitor(session_pid)
      queue_empty? = queue_empty?(snapshot)
      lifecycle = SessionLifecycle.evolve(:created, snapshot.status, queue_empty?)

      record = %{
        session_id: snapshot.session_id,
        workspace_id: workspace_id,
        pid: session_pid,
        inserted_at_ms: now,
        status: snapshot.status,
        lifecycle: lifecycle,
        last_active_at_ms: now,
        idle_since_at_ms: if(lifecycle == :idle, do: now, else: nil),
        last_snapshot_at_ms: now,
        idle_ttl_ms: idle_ttl_ms(config, opts),
        capability_packs: capability_packs,
        capability_allowlist: capability_allowlist
      }

      next_state = %{
        state
        | sessions: Map.put(state.sessions, session_pid, record),
          monitors: Map.put(state.monitors, ref, session_pid)
      }

      reply = %{
        pid: session_pid,
        session_id: record.session_id,
        workspace_id: workspace_id,
        capability_packs: capability_packs
      }

      {:ok, reply, next_state}
    else
      {:error, reason} -> {:error, reason, state}
      _ -> {:error, :invalid_session_snapshot, state}
    end
  end

  defp find_session_record_by_id(sessions, session_id) do
    sessions
    |> Map.values()
    |> Enum.find(fn record -> record.session_id == session_id end)
    |> case do
      nil -> :error
      record -> {:ok, record}
    end
  end

  defp resolve_session_capabilities(state, config, workspace_id, opts) do
    requested_packs =
      opts
      |> Keyword.get_lazy(:capability_packs, fn ->
        Map.get(
          state.workspace_capability_packs,
          workspace_id,
          Map.get(config, :capability_packs, [])
        )
      end)
      |> normalize_pack_list()

    allowlist =
      opts
      |> Keyword.get(:capability_allowlist, Map.get(config, :workspace_capability_allowlist, []))
      |> normalize_pack_list()

    with :ok <- ensure_capabilities_allowed(requested_packs, allowlist),
         {:ok, tools} <- PackRegistry.resolve_tools(requested_packs) do
      session_config =
        config
        |> Map.put(:capability_packs, requested_packs)
        |> Map.put(:workspace_capability_allowlist, allowlist)
        |> Map.put(:tools, tools)

      {:ok, session_config, requested_packs, allowlist}
    end
  end

  defp ensure_capabilities_allowed(requested_packs, allowlist) do
    case Enum.find(requested_packs, fn pack -> not Enum.member?(allowlist, pack) end) do
      nil -> :ok
      denied_pack -> {:error, {:capability_not_allowed, denied_pack}}
    end
  end

  defp normalize_pack_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
  end

  defp normalize_pack_list(_), do: []

  defp schedule_sync(state) do
    Process.send_after(self(), :sync_sessions, state.sync_interval_ms)
    state
  end
end
