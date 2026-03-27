defmodule Prehen.Tools.PackRegistryTest do
  use ExUnit.Case

  alias Prehen.Agents.Profile
  alias Prehen.Config
  alias Prehen.Workspace.Paths
  alias Prehen.Tools.PackRegistry

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "prehen_pack_registry_workspace_#{System.unique_integer([:positive])}"
      )

    global =
      Path.join(
        System.tmp_dir!(),
        "prehen_pack_registry_global_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Paths.config_dir(workspace))
    File.mkdir_p!(Paths.global_config_dir(global))

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(global)
    end)

    %{workspace: workspace, global: global}
  end

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

  test "loads local agent profiles for gateway routing" do
    config = Config.load(agent_profiles: [fake_stdio: [command: ["elixir", "fake.exs"]]])

    assert [%Profile{name: "fake_stdio"}] = config.agent_profiles
  end

  test "loads agent profiles from structured runtime config", %{
    workspace: workspace,
    global: global
  } do
    File.write!(
      Path.join(Paths.config_dir(workspace), "runtime.yaml"),
      """
      runtime:
        agent_profiles:
          fake_stdio:
            command: ["elixir", "fake.exs"]
            transport: stdio
      """
    )

    config = Config.load(workspace_dir: workspace, global_dir: global)

    assert [
             %Profile{
               name: "fake_stdio",
               command: "elixir",
               args: ["fake.exs"],
               transport: :stdio
             }
           ] =
             config.agent_profiles
  end

  test "raises on malformed agent profiles" do
    assert_raise ArgumentError, ~r/invalid agent profile/, fn ->
      Config.load(
        agent_profiles: [fake_stdio: [command: ["elixir", "fake.exs"], transport: "ssh"]]
      )
    end
  end

  test "raises on duplicate agent profile names" do
    assert_raise ArgumentError, ~r/duplicate agent profile name/, fn ->
      Config.load(
        agent_profiles: [
          {:fake_stdio, [command: ["elixir", "one.exs"]]},
          {"fake_stdio", [command: ["elixir", "two.exs"]]}
        ]
      )
    end
  end
end
