defmodule Prehen.Tools.PackRegistryTest do
  use ExUnit.Case

  alias Prehen.Tools.PackRegistry

  defmodule NotesPack do
    @behaviour Prehen.Tools.CapabilityPack

    @impl true
    def name, do: :notes

    @impl true
    def tools, do: [Prehen.Actions.Read]
  end

  test "default local_fs pack resolves ls/read tools" do
    assert {:ok, tools} = PackRegistry.resolve_tools([:local_fs])
    assert Prehen.Actions.LS in tools
    assert Prehen.Actions.Read in tools
  end

  test "registers custom pack and resolves tools" do
    assert :ok = PackRegistry.register_pack(NotesPack)
    assert {:ok, [Prehen.Actions.Read]} = PackRegistry.resolve_tools([:notes])
  end

  test "returns error for unknown packs" do
    assert {:error, {:capability_pack_not_found, :missing_pack}} =
             PackRegistry.resolve_tools([:missing_pack])
  end
end
