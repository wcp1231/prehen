defmodule Prehen.Agents.Protocol.Frame do
  @moduledoc false

  def session_open(attrs) do
    payload =
      attrs
      |> Enum.into(%{})
      |> drop_nil_values()

    %{type: "session.open", payload: payload}
  end

  def session_message(attrs) do
    %{type: "session.message", payload: attrs |> Enum.into(%{}) |> drop_nil_values()}
  end

  def session_control(attrs) do
    %{type: "session.control", payload: attrs |> Enum.into(%{}) |> drop_nil_values()}
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
