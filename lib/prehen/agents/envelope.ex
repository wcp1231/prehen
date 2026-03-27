defmodule Prehen.Agents.Envelope do
  @moduledoc false

  def build(type, attrs) do
    %{
      type: type,
      gateway_session_id: Map.fetch!(attrs, :gateway_session_id),
      agent_session_id: Map.fetch!(attrs, :agent_session_id),
      agent: Map.fetch!(attrs, :agent),
      node: Atom.to_string(node()),
      seq: Map.fetch!(attrs, :seq),
      timestamp: System.system_time(:millisecond),
      payload: Map.get(attrs, :payload, %{}),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end
end
