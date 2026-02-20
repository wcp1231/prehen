defmodule Prehen.Tools.CapabilityPack do
  @moduledoc false

  @callback name() :: atom()
  @callback tools() :: [module()]
end
