defmodule Prehen.Agent.RuntimeTest do
  use ExUnit.Case

  alias Prehen.Agent.Runtime

  test "delegates successful execution to configured backend" do
    Prehen.Test.MockBackend.set_results([
      {:ok, %{status: :ok, answer: "done", steps: 2, trace: [%{event: :finished}]}}
    ])

    assert {:ok, result} =
             Runtime.run("inspect files",
               agent_backend: Prehen.Test.MockBackend,
               root_dir: ".",
               max_steps: 5
             )

    assert result.status == :ok
    assert result.answer == "done"
    assert [%{event: :finished}] = result.trace
  end

  test "returns backend failure as runtime failure" do
    Prehen.Test.MockBackend.set_results([
      {:error, %{status: :error, reason: :unknown_provider, trace: [%{event: :failed}]}}
    ])

    assert {:error, result} =
             Runtime.run("bad config",
               agent_backend: Prehen.Test.MockBackend
             )

    assert result.status == :error
    assert result.reason == :unknown_provider
  end

  test "uses session runtime path for jido backend" do
    assert {:ok, result} =
             Runtime.run("hello",
               agent_backend: Prehen.Agent.Backends.JidoAI,
               session_adapter: Prehen.Test.FakeSessionAdapter,
               timeout_ms: 600,
               max_steps: 4
             )

    assert result.status == :ok
    assert result.answer == "answer:hello"
    assert Enum.any?(result.trace, &(&1.type == "ai.request.started"))
    assert Enum.any?(result.trace, &(&1.type == "ai.request.completed"))
  end
end
