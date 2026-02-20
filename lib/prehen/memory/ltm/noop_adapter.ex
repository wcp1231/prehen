defmodule Prehen.Memory.LTM.NoopAdapter do
  @moduledoc false

  @behaviour Prehen.Memory.LTM.Adapter

  @impl true
  def get(_session_id, _query), do: {:ok, nil}

  @impl true
  def put(_session_id, _entry, _meta), do: :ok
end
