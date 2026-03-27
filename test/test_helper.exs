defmodule PrehenWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      import Phoenix.ChannelTest

      @endpoint PrehenWeb.Endpoint
    end
  end
end

ExUnit.start()
