defmodule Prehen.Workspace.SessionLifecycle do
  @moduledoc false

  @type t :: :created | :running | :idle | :stopping | :reclaimed

  @spec evolve(t(), atom(), boolean()) :: t()
  def evolve(:stopping, _runtime_status, _queue_empty), do: :stopping
  def evolve(:reclaimed, _runtime_status, _queue_empty), do: :reclaimed

  def evolve(_current, :running, _queue_empty), do: :running
  def evolve(_current, :idle, true), do: :idle
  def evolve(current, _runtime_status, _queue_empty), do: current
end
