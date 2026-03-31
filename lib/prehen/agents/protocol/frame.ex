defmodule Prehen.Agents.Protocol.Frame do
  @moduledoc false

  def session_open(attrs) do
    payload =
      attrs
      |> normalize_attrs()
      |> drop_nil_values()

    %{type: "session.open", payload: payload}
  end

  def session_message(attrs) do
    %{type: "session.message", payload: attrs |> normalize_attrs() |> drop_nil_values()}
  end

  def session_control(attrs) do
    %{type: "session.control", payload: attrs |> normalize_attrs() |> drop_nil_values()}
  end

  defp normalize_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_attrs(attrs), do: Enum.into(attrs, %{})

  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc ->
        Map.put(acc, key, drop_nil_values(value))
    end)
  end

  defp drop_nil_values(list) when is_list(list), do: Enum.map(list, &drop_nil_values/1)
  defp drop_nil_values(value), do: value
end
