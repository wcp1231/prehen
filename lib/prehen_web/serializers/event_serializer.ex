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
    event
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case convert_value(value) do
        :drop -> acc
        converted -> Map.put(acc, convert_key(key), converted)
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

  defp convert_value(value) when is_map(value), do: serialize(value)

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
end
