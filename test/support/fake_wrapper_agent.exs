#!/usr/bin/env elixir

defmodule FakeWrapperAgent do
  def main do
    loop(%{agent_session_id: nil})
  end

  defp loop(state) do
    case IO.gets(:stdio, "") do
      nil ->
        :ok

      :eof ->
        :ok

      line ->
        case Jason.decode(String.trim(line)) do
          {:ok, %{"type" => "session.open", "payload" => payload}} ->
            next_state = open_session(payload)
            loop(next_state)

          {:ok,
           %{
             "type" => "session.message",
             "payload" => %{"agent_session_id" => agent_session_id} = payload
           }} ->
            emit_reply(agent_session_id, payload["message_id"] || "message_1")
            loop(state)

          {:ok, %{"type" => "session.control"}} ->
            loop(state)

          _ ->
            loop(state)
        end
    end
  end

  defp open_session(payload) do
    maybe_delay_open()

    provider = payload_value(payload, "provider")
    model = payload_value(payload, "model")
    prompt_profile = payload_value(payload, "prompt_profile")

    agent_session_id = "agent_#{provider}_#{model}_#{prompt_profile}"

    IO.puts(
      Jason.encode!(%{
        type: "session.opened",
        payload: %{
          ready: true,
          agent_session_id: agent_session_id,
          workspace: payload_value(payload, "workspace")
        }
      })
    )

    %{agent_session_id: agent_session_id}
  end

  defp emit_reply(agent_session_id, message_id) do
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
  end

  defp payload_value(payload, key) do
    payload[key] ||
      get_in(payload, ["prompt", key]) ||
      get_in(payload, ["prompt", "session", key]) ||
      "missing"
  end

  defp maybe_delay_open do
    case System.get_env("FAKE_WRAPPER_OPEN_DELAY_MS") do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {delay_ms, ""} when delay_ms > 0 -> Process.sleep(delay_ms)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end
end

FakeWrapperAgent.main()
