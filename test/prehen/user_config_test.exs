defmodule Prehen.UserConfigTest do
  use ExUnit.Case, async: false

  alias Prehen.Home
  alias Prehen.UserConfig

  setup do
    original_home = System.get_env("PREHEN_HOME")

    on_exit(fn ->
      case original_home do
        nil -> System.delete_env("PREHEN_HOME")
        value -> System.put_env("PREHEN_HOME", value)
      end
    end)

    :ok
  end

  test "loads profiles providers and channels from config.yaml" do
    root =
      Path.join(System.tmp_dir!(), "prehen_user_config_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    File.write!(Path.join(root, "config.yaml"), """
    profiles:
      - id: coder
        label: Coder
        description: Writes and reviews code
        runtime: pi
        default_provider: github-copilot
        default_model: gpt-5.4-mini
        enabled: true
    providers:
      github-copilot:
        type: openai_compatible
    channels:
      web:
        enabled: true
    """)

    assert {:ok, config} = UserConfig.load(root: root)

    assert config == %{
             profiles: [
               %{
                 id: "coder",
                 label: "Coder",
                 description: "Writes and reviews code",
                 runtime: "pi",
                 default_provider: "github-copilot",
                 default_model: "gpt-5.4-mini",
                 enabled: true
               }
             ],
             providers: %{"github-copilot" => %{"type" => "openai_compatible"}},
             channels: %{"web" => %{"enabled" => true}}
           }
  end

  test "loads config.yaml from the default Prehen home root" do
    root =
      Path.join(
        System.tmp_dir!(),
        "prehen_user_config_default_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    System.put_env("PREHEN_HOME", root)

    File.write!(Home.path("config.yaml"), """
    profiles:
      - id: reviewer
        label: Reviewer
        runtime: pi
        default_provider: github-copilot
        default_model: gpt-5.4-mini
        enabled: false
    """)

    assert {:ok, config} = UserConfig.load()

    assert config == %{
             profiles: [
               %{
                 id: "reviewer",
                 label: "Reviewer",
                 description: nil,
                 runtime: "pi",
                 default_provider: "github-copilot",
                 default_model: "gpt-5.4-mini",
                 enabled: false
               }
             ],
             providers: %{},
             channels: %{}
           }
  end

  test "returns an error when config.yaml is missing" do
    root =
      Path.join(
        System.tmp_dir!(),
        "prehen_user_config_missing_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    assert {:error, _reason} = UserConfig.load(root: root)
  end
end
