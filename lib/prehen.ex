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

  @spec resume_session(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def resume_session(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    Surface.resume_session(session_id, opts)
  end

  @spec submit_message(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def submit_message(session_id, text, opts \\ [])
      when is_binary(session_id) and is_binary(text) do
    Surface.submit_message(session_id, text, opts)
  end

  @spec stop_session(String.t()) :: :ok | {:error, map()}
  def stop_session(session_id) when is_binary(session_id) do
    Surface.stop_session(session_id)
  end

  @spec await_result(pid(), keyword()) :: {:ok, map()} | {:error, map()}
  def await_result(session_pid, opts \\ []) when is_pid(session_pid) and is_list(opts) do
    Surface.await_result(session_pid, opts)
  end

  @spec list_sessions(keyword()) :: [map()]
  def list_sessions(opts \\ []) do
    Surface.list_sessions(opts)
  end

  @spec session_status(String.t()) :: {:ok, map()} | {:error, map()}
  def session_status(session_id) when is_binary(session_id) do
    Surface.session_status(session_id)
  end

  @spec replay_session(String.t(), keyword()) :: [map()]
  def replay_session(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    Surface.replay_session(session_id, opts)
  end

  @spec set_capability_packs([atom()], keyword()) :: :ok | {:error, term()}
  def set_capability_packs(packs, opts \\ []) when is_list(packs) and is_list(opts) do
    Surface.set_capability_packs(packs, opts)
  end

  @spec subscribe_events(String.t()) :: {:ok, map()} | {:error, map()}
  def subscribe_events(session_id) when is_binary(session_id) do
    Surface.subscribe_events(session_id)
  end
end
