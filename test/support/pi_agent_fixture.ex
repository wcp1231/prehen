defmodule Prehen.TestSupport.PiAgentFixture do
  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile
  alias Prehen.Agents.Registry
  alias Prehen.Agents.Wrappers.PiCodingAgent

  @python System.find_executable("python3") || "python3"
  @fake_pi_path Path.expand("fake_pi_json_agent.py", __DIR__)

  def profile(name \\ "coder", opts \\ []) do
    label = Keyword.get(opts, :label, humanize(name))
    prompt_profile = Keyword.get(opts, :prompt_profile, "#{name}_default")

    %Profile{
      name: name,
      label: label,
      description: Keyword.get(opts, :description, default_description(name)),
      implementation: Keyword.get(opts, :implementation, "#{name}_impl"),
      default_provider: Keyword.get(opts, :default_provider, "openai"),
      default_model: Keyword.get(opts, :default_model, "gpt-5"),
      prompt_profile: prompt_profile,
      workspace_policy: Keyword.get(opts, :workspace_policy, %{mode: "scoped"})
    }
  end

  def implementation(name \\ "coder", env \\ %{}, opts \\ []) do
    %Implementation{
      name: Keyword.get(opts, :name, "#{name}_impl"),
      command: Keyword.get(opts, :command, @python),
      args: Keyword.get(opts, :args, [@fake_pi_path]),
      env: normalize_env(env),
      wrapper: Keyword.get(opts, :wrapper, PiCodingAgent)
    }
  end

  def registry_state(
        profile_or_profiles \\ "coder",
        env_or_implementations \\ %{},
        supported_names \\ nil
      )

  def registry_state(profile_name, env, nil) when is_binary(profile_name) and is_map(env) do
    profile = profile(profile_name)
    implementation = implementation(profile_name, env)
    registry_state([profile], [implementation])
  end

  def registry_state(profiles, implementations, supported_names)
      when is_list(profiles) and is_list(implementations) do
    supported_names = supported_names || Enum.map(profiles, & &1.name)
    supported_profiles = Enum.filter(profiles, &(&1.name in supported_names))

    %{
      ordered: profiles,
      by_name: Map.new(profiles, fn %Profile{name: name} = profile -> {name, profile} end),
      supported_ordered: supported_profiles,
      supported_by_name:
        Map.new(supported_profiles, fn %Profile{name: name} = profile -> {name, profile} end),
      implementations_ordered: implementations,
      implementations_by_name:
        Map.new(implementations, fn %Implementation{name: name} = implementation ->
          {name, implementation}
        end)
    }
  end

  def replace_registry!(state) when is_map(state) do
    registry_pid = Process.whereis(Registry)
    original = :sys.get_state(registry_pid)
    :sys.replace_state(registry_pid, fn _ -> state end)
    original
  end

  def restore_registry!(original_state) do
    registry_pid = Process.whereis(Registry)
    :sys.replace_state(registry_pid, fn _ -> original_state end)
  end

  def workspace!(label \\ "workspace") do
    path =
      Path.join(
        System.tmp_dir!(),
        "prehen_pi_fixture_#{sanitize(label)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp normalize_env(env) when is_map(env),
    do: Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp humanize(name) do
    name
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp default_description("coder"), do: "General coding profile"
  defp default_description(name), do: "#{name} profile"

  defp sanitize(label) do
    label
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "_")
  end
end
