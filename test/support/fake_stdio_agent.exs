#!/usr/bin/env elixir

defmodule FakeStdioAgent do
  def main do
    loop()
  end

  defp loop do
    case IO.gets(:stdio, "") do
      nil ->
        :ok

      :eof ->
        :ok

      line ->
        case Jason.decode(String.trim(line)) do
          {:ok,
           %{
             "type" => "session.open",
             "payload" => %{"gateway_session_id" => gateway_session_id}
           }} ->
            if emit_stderr?() do
              IO.puts(:stderr, "fake agent diagnostic")
            end

            IO.puts(
              Jason.encode!(%{
                type: "session.opened",
                payload: %{
                  ready: true,
                  agent_session_id: "agent_#{gateway_session_id}"
                }
              })
            )

            loop()

          {:ok,
           %{
             "type" => "session.message",
             "payload" => %{"agent_session_id" => agent_session_id} = payload
           }} ->
            message_id = payload["message_id"] || "message_1"

            IO.puts(
              Jason.encode!(%{
                type: "session.output.delta",
                payload: %{
                  agent_session_id: agent_session_id,
                  message_id: message_id,
                  text: "hi"
                }
              })
            )

            IO.puts(
              Jason.encode!(%{
                type: "session.output.completed",
                payload: %{
                  agent_session_id: agent_session_id,
                  message_id: message_id
                }
              })
            )

            loop()

          {:ok, %{"type" => "session.control", "payload" => _payload}} ->
            loop()

          _ ->
            loop()
        end
    end
  end

  defp emit_stderr? do
    System.get_env("FAKE_STDIO_EMIT_STDERR") in ["1", "true"]
  end
end

FakeStdioAgent.main()
