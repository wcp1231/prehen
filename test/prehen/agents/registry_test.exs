defmodule Prehen.Agents.RegistryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Prehen.Agents.Registry
  alias Prehen.TestSupport.PiAgentFixture

  test "logs unsupported profiles during init and filters them out" do
    profile = PiAgentFixture.profile("coder")

    implementation =
      PiAgentFixture.implementation("coder", %{"FAKE_PI_MODE" => "invalid_header"})

    log =
      capture_log(fn ->
        assert {:ok, state} =
                 Registry.init(
                   profiles: [profile],
                   implementations: [implementation]
                 )

        assert state.ordered == [profile]
        assert state.supported_ordered == []
        assert state.supported_by_name == %{}
      end)

    assert log =~ ~s(agent profile "coder" filtered out)
    assert log =~ "contract_failed"
  end
end
