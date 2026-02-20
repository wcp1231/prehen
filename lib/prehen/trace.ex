defmodule Prehen.Trace do
  @moduledoc """
  Trace 辅助模块（typed envelope 版本）。

  中文：
  - 提供轻量 trace 构建工具，统一转换为 typed event 结构。
  - 不再输出旧版 `event/at` 结构，直接对齐 `EventBridge` 契约。

  English:
  - Lightweight helper for building typed trace events.
  - No legacy `event/at` mapping; emits EventBridge-compatible envelopes.
  """

  alias Prehen.Agent.EventBridge

  @spec new() :: [map()]
  def new, do: []

  @spec add([map()], atom() | String.t(), map()) :: [map()]
  def add(events, event_type, payload \\ %{}) do
    normalized_type = normalize_type(event_type)
    events ++ [EventBridge.project(normalized_type, payload, source: "prehen.trace")]
  end

  defp normalize_type(value) when is_binary(value) and value != "", do: value
  defp normalize_type(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_type(_), do: "ai.trace.event"
end
