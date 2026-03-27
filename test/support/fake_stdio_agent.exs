#!/usr/bin/env elixir

defmodule FakeStdioAgent do
  def main do
    loop()
  end

  defp loop do
    case IO.gets(:stdio, "") do
      nil ->
        :ok

      line ->
        case Jason.decode(String.trim(line)) do
          {:ok, %{"type" => "session.open", "gateway_session_id" => gateway_session_id}} ->
            IO.puts(
              Jason.encode!(%{
                type: "session.opened",
                agent_session_id: "agent_#{gateway_session_id}",
                payload: %{
                  ready: true
                }
              })
            )

            loop()

          {:ok, %{"type" => "session.message", "agent_session_id" => agent_session_id} = frame} ->
            IO.puts(
              Jason.encode!(%{
                type: "session.output.delta",
                agent_session_id: agent_session_id,
                payload: %{
                  message: frame["message_id"] || "message_1",
                  text: "hi"
                }
              })
            )

            loop()

          {:ok, %{"type" => "session.control"}} ->
            loop()

          _ ->
            loop()
        end
    end
  end
end

FakeStdioAgent.main()
