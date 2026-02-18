defmodule PrehenTest do
  use ExUnit.Case

  test "delegates to runtime and returns structured result" do
    Prehen.Test.MockBackend.set_results([
      {:ok, %{answer: "done", status: :ok, trace: []}}
    ])

    assert {:ok, %{answer: "done", status: :ok}} =
             Prehen.run("say done", agent_backend: Prehen.Test.MockBackend)
  end
end
