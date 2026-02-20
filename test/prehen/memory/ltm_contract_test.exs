defmodule Prehen.Memory.LTMContractTest do
  use ExUnit.Case

  alias Prehen.Memory
  alias Prehen.Memory.LTMAdapters

  defmodule MockAdapter do
    @behaviour Prehen.Memory.LTM.Adapter

    @impl true
    def get(session_id, query) do
      {:ok, %{adapter: :mock, session_id: session_id, query: query}}
    end

    @impl true
    def put(_session_id, _entry, _meta), do: :ok
  end

  defmodule StubAdapter do
    @behaviour Prehen.Memory.LTM.Adapter

    @impl true
    def get(session_id, query) do
      {:ok, %{adapter: :stub, session_id: session_id, query: query}}
    end

    @impl true
    def put(_session_id, _entry, _meta), do: :ok
  end

  setup do
    assert :ok = LTMAdapters.register(:mock, MockAdapter)
    assert :ok = LTMAdapters.register(:stub, StubAdapter)
    :ok
  end

  test "mock and stub adapters satisfy the same memory contract" do
    Enum.each([:mock, :stub], fn adapter_name ->
      session_id = unique_session_id(adapter_name)

      assert {:ok, _} = Memory.ensure_session(session_id)

      assert {:ok, write_result} =
               Memory.record_turn(session_id, %{input: "hello", output: "world"},
                 ltm_adapter_name: adapter_name
               )

      assert write_result.ltm_write == :ok

      assert {:ok, context} = Memory.context(session_id, ltm_adapter_name: adapter_name)
      assert context.source == :stm_plus_ltm
      assert context.ltm.adapter == adapter_name
      assert context.ltm.session_id == session_id
      assert is_map(context.ltm.query)
      assert is_list(context.stm.conversation_buffer)
      assert context.ltm_error == nil
    end)
  end

  defp unique_session_id(adapter_name) do
    "#{adapter_name}_#{System.unique_integer([:positive])}"
  end
end
