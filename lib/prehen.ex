defmodule Prehen do
  @moduledoc """
  Prehen 平台公开 API。

  中文：
  - 对外提供运行、会话生命周期、消息提交与事件订阅等能力。
  - 使用统一 client surface 入口。

  English:
  - Public API for runtime execution, session lifecycle, messaging, and event subscription.
  - Uses the unified client surface as the primary entrypoint.
  """

  alias Prehen.Client.Surface

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(task, opts \\ []) when is_binary(task) do
    Surface.run(task, opts)
  end

  @spec create_session(keyword()) :: {:ok, map()} | {:error, map()}
  def create_session(opts \\ []) do
    Surface.create_session(opts)
  end

  @spec submit_message(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def submit_message(session_pid, text, opts \\ [])
      when is_pid(session_pid) and is_binary(text) do
    Surface.submit_message(session_pid, text, opts)
  end

  @spec stop_session(pid()) :: :ok | {:error, map()}
  def stop_session(session_pid) when is_pid(session_pid) do
    Surface.stop_session(session_pid)
  end

  @spec await_result(pid(), keyword()) :: {:ok, map()} | {:error, map()}
  def await_result(session_pid, opts \\ []) when is_pid(session_pid) and is_list(opts) do
    Surface.await_result(session_pid, opts)
  end

  @spec list_sessions(keyword()) :: [map()]
  def list_sessions(opts \\ []) do
    Surface.list_sessions(opts)
  end

  @spec session_status(pid()) :: {:ok, map()} | {:error, map()}
  def session_status(session_pid) when is_pid(session_pid) do
    Surface.session_status(session_pid)
  end

  @spec replay_session(String.t(), keyword()) :: [map()]
  def replay_session(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    Surface.replay_session(session_id, opts)
  end

  @spec set_workspace_capability_packs(String.t(), [atom()]) :: :ok | {:error, term()}
  def set_workspace_capability_packs(workspace_id, packs)
      when is_binary(workspace_id) and is_list(packs) do
    Surface.set_workspace_capability_packs(workspace_id, packs)
  end

  @spec subscribe_events(String.t()) :: {:ok, map()} | {:error, map()}
  def subscribe_events(session_id) when is_binary(session_id) do
    Surface.subscribe_events(session_id)
  end
end
