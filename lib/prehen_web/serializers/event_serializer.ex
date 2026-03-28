defmodule PrehenWeb.EventSerializer do
  @moduledoc """
  将 Elixir 内部事件结构转换为 JSON 安全的 map。

  处理规则：
  - `{:ok, value}` → `%{"status" => "ok", "value" => value}`
  - `{:error, reason}` → `%{"status" => "error", "reason" => inspect(reason)}`
  - atom → string
  - pid → 移除
  - 嵌套 map/list → 递归转换
  - string/number/boolean/nil → 保持原样
  """

  @spec serialize(map()) :: map()
  def serialize(event) when is_map(event) do
    do_serialize(event, true)
  end

  defp do_serialize(event, top_level?) when is_map(event) do
    is_request_failed = match?(%{type: "ai.request.failed"}, event) or
                        match?(%{"type" => "ai.request.failed"}, event)

    event
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      str_key = convert_key(key)

      converted =
        cond do
          top_level? and runtime_specific_field?(str_key) and not inbox_browser_field?(str_key) ->
            :drop

          is_request_failed and str_key == "error" ->
            normalize_error(value)

          true ->
            convert_value(value)
        end

      case converted do
        :drop -> acc
        val -> Map.put(acc, str_key, val)
      end
    end)
  end

  defp convert_key(key) when is_atom(key), do: Atom.to_string(key)
  defp convert_key(key), do: key

  defp convert_value(value) when is_pid(value), do: :drop
  defp convert_value(value) when is_reference(value), do: :drop
  defp convert_value(value) when is_function(value), do: :drop
  defp convert_value(value) when is_port(value), do: :drop

  defp convert_value({:ok, value}),
    do: %{"status" => "ok", "value" => convert_value(value)}

  defp convert_value({:error, reason}),
    do: %{"status" => "error", "reason" => inspect(reason)}

  defp convert_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp convert_value(value) when is_map(value), do: do_serialize(value, false)

  defp convert_value(value) when is_list(value),
    do: Enum.flat_map(value, fn item ->
      case convert_value(item) do
        :drop -> []
        converted -> [converted]
      end
    end)

  defp convert_value(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> convert_value()

  defp convert_value(value), do: value

  # -- Error normalization for ai.request.failed events --

  defp normalize_error(%{code: code} = map) when is_atom(code) or is_binary(code) do
    reason = map[:reason]
    message = if is_binary(reason), do: reason, else: inspect(reason)

    details =
      map
      |> Map.drop([:code, :reason])
      |> case do
        empty when map_size(empty) == 0 -> nil
        rest -> serialize(rest)
      end

    result = %{"code" => to_string(code), "message" => message}
    if details, do: Map.put(result, "details", details), else: result
  end

  defp normalize_error({:model_fallback_exhausted, %{} = info}) do
    message =
      case info[:model_error] do
        %{reason: r} when is_binary(r) -> r
        other when not is_nil(other) -> inspect(other)
        _ -> "All model fallbacks exhausted"
      end

    %{
      "code" => "model_fallback_exhausted",
      "message" => message,
      "details" => serialize(info)
    }
  end

  defp normalize_error({:await_crash, reason}) do
    %{
      "code" => "await_crash",
      "message" => "Session process crashed",
      "details" => %{"reason" => inspect(reason)}
    }
  end

  defp normalize_error({:cancelled, :steering}) do
    %{"code" => "cancelled", "message" => "Request cancelled by user"}
  end

  defp normalize_error(:timeout) do
    %{"code" => "timeout", "message" => "Request timed out"}
  end

  defp normalize_error(value) when is_atom(value) do
    %{"code" => to_string(value), "message" => to_string(value)}
  end

  defp normalize_error(value) do
    %{"code" => "unknown", "message" => inspect(value)}
  end

  defp runtime_specific_field?("node"), do: true
  defp runtime_specific_field?("timestamp"), do: true
  defp runtime_specific_field?(_), do: false

  # Explicitly pin the event fields the inbox browser depends on.
  defp inbox_browser_field?("type"), do: true
  defp inbox_browser_field?("gateway_session_id"), do: true
  defp inbox_browser_field?("agent_session_id"), do: true
  defp inbox_browser_field?("payload"), do: true
  defp inbox_browser_field?(_), do: false
end
