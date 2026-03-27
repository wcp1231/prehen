defmodule Prehen do
  @moduledoc """
  Prehen 平台公开 API。

  中文：
  - 对外提供当前 Gateway MVP 的运行、会话生命周期与消息提交能力。
  - 使用统一 client surface 入口。

  English:
  - Public API for the current gateway MVP execution, session lifecycle, and messaging flows.
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

  @spec submit_message(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def submit_message(session_id, text, opts \\ [])
      when is_binary(session_id) and is_binary(text) do
    Surface.submit_message(session_id, text, opts)
  end

  @spec stop_session(String.t()) :: :ok | {:error, map()}
  def stop_session(session_id) when is_binary(session_id) do
    Surface.stop_session(session_id)
  end

  @spec session_status(String.t()) :: {:ok, map()} | {:error, map()}
  def session_status(session_id) when is_binary(session_id) do
    Surface.session_status(session_id)
  end
end
