defmodule Prehen.Trace do
  @moduledoc false

  @spec new() :: [map()]
  def new, do: []

  @spec add([map()], atom(), map()) :: [map()]
  def add(events, event, payload \\ %{}) do
    events ++
      [
        Map.merge(
          %{
            event: event,
            at: DateTime.utc_now() |> DateTime.to_iso8601()
          },
          payload
        )
      ]
  end
end
