defmodule Prehen.Agent.Runtime do
  @moduledoc """
  运行时门面（runtime facade），对外暴露会话生命周期与执行入口。

  中文：
  - 对外隐藏 `SessionManager/Session` 的内部细节。
  - 在 Jido backend 下统一走 session 路径，保证行为一致。
  - 提供会话状态、回放、workspace capability 控制等平台 API。

  English:
  - Runtime facade exposing session lifecycle and execution APIs.
  - Hides internal `SessionManager/Session` orchestration details.
  - Uses the session-oriented path for Jido backend to keep behavior consistent.
  - Exposes platform APIs for status, replay, and workspace capability control.
  """

  alias Prehen.Config
  alias Prehen.Agent.Session
  alias Prehen.Conversation.Store
  alias Prehen.Workspace.SessionManager

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(task, opts \\ []) when is_binary(task) do
    config = Config.load(opts)
    backend = config[:agent_backend]

    if backend == Prehen.Agent.Backends.JidoAI do
      run_via_session(task, config)
    else
      backend.run(task, config)
    end
  end

  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ []) do
    config = Config.load(opts)
    workspace_id = opts |> Keyword.get(:workspace_id, "default") |> to_string()

    manager_opts =
      [workspace_id: workspace_id] ++
        Keyword.take(opts, [:name, :capability_packs, :capability_allowlist])

    case SessionManager.start_session(config, manager_opts) do
      {:ok, %{pid: session_pid}} -> {:ok, session_pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stop_session(pid()) :: :ok
  def stop_session(session_pid) when is_pid(session_pid) do
    case SessionManager.stop_session(session_pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        if Process.alive?(session_pid) do
          Session.stop(session_pid)
        else
          :ok
        end
    end
  end

  @spec prompt(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def prompt(session_pid, text, opts \\ []) when is_pid(session_pid) and is_binary(text) do
    Session.prompt(session_pid, text, opts)
  end

  @spec steer(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def steer(session_pid, text, opts \\ []) when is_pid(session_pid) and is_binary(text) do
    Session.steer(session_pid, text, opts)
  end

  @spec follow_up(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def follow_up(session_pid, text, opts \\ []) when is_pid(session_pid) and is_binary(text) do
    Session.follow_up(session_pid, text, opts)
  end

  @spec await_idle(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_idle(session_pid, opts \\ []) when is_pid(session_pid) do
    Session.await_idle(session_pid, opts)
  end

  @spec list_sessions(keyword()) :: [map()]
  def list_sessions(opts \\ []) do
    workspace_id =
      opts
      |> Keyword.get(:workspace_id)
      |> normalize_workspace_id()

    SessionManager.list_sessions(workspace_id)
  end

  @spec session_status(pid()) :: {:ok, map()} | {:error, term()}
  def session_status(session_pid) when is_pid(session_pid) do
    with {:ok, record} <- SessionManager.get_session(session_pid) do
      {:ok, Map.merge(record, %{snapshot: Session.snapshot(session_pid)})}
    end
  end

  @spec replay_session(String.t(), keyword()) :: [map()]
  def replay_session(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    Store.replay(session_id, opts)
  end

  @spec set_workspace_capability_packs(String.t(), [atom()]) :: :ok | {:error, term()}
  def set_workspace_capability_packs(workspace_id, packs)
      when is_binary(workspace_id) and is_list(packs) do
    SessionManager.set_workspace_capability_packs(workspace_id, packs)
  end

  defp run_via_session(task, config) do
    timeout = config[:timeout_ms] * max(config[:max_steps], 1) * 2

    with {:ok, %{pid: session}} <- SessionManager.start_session(config, workspace_id: "runtime") do
      try do
        with {:ok, _} <- Session.prompt(session, task),
             {:ok, result} <- Session.await_idle(session, timeout: timeout) do
          {:ok, result}
        end
      after
        if Process.alive?(session), do: stop_session(session)
      end
    end
  end

  defp normalize_workspace_id(nil), do: nil
  defp normalize_workspace_id(value), do: to_string(value)
end
