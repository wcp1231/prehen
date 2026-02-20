defmodule Prehen.Events do
  @moduledoc """
  事件访问门面（subscribe/replay）。

  中文：
  - 对客户端暴露最小事件能力：订阅实时事件、回放历史记录。
  - 隐藏底层 `ProjectionSupervisor` 与 `Conversation.Store` 细节。

  English:
  - Minimal event facade for clients (subscribe + replay).
  - Hides internals of `ProjectionSupervisor` and `Conversation.Store`.
  """

  alias Prehen.Conversation.Store
  alias Prehen.Events.ProjectionSupervisor

  @spec subscribe(String.t()) :: {:ok, %{session_id: String.t()}} | {:error, term()}
  def subscribe(session_id) when is_binary(session_id) do
    ProjectionSupervisor.subscribe(session_id)
  end

  @spec replay(String.t(), keyword()) :: [map()]
  def replay(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    Store.replay(session_id, opts)
  end
end
