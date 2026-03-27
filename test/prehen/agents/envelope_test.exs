defmodule Prehen.Agents.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Prehen.Agents.Envelope

  test "normalizes explicit nil payload and metadata to empty maps" do
    envelope =
      Envelope.build("session.output.delta", %{
        gateway_session_id: "gw_1",
        agent_session_id: "agent_gw_1",
        agent: "fake_stdio",
        seq: 1,
        payload: nil,
        metadata: nil
      })

    assert envelope.payload == %{}
    assert envelope.metadata == %{}
  end
end
