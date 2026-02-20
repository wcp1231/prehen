defmodule Prehen.Tools.Packs.LocalFS do
  @moduledoc false

  @behaviour Prehen.Tools.CapabilityPack

  @impl true
  def name, do: :local_fs

  @impl true
  def tools do
    [Prehen.Actions.LS, Prehen.Actions.Read]
  end
end
