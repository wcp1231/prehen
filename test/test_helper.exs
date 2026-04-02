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

Code.require_file("support/pi_agent_fixture.ex", __DIR__)

ExUnit.start()
