defmodule Prehen.Agents.PromptContext do
  @moduledoc false

  alias Prehen.Agents.SessionConfig

  @spec build(SessionConfig.t() | struct(), keyword()) :: map()
  def build(%SessionConfig{} = session_config, opts \\ []) do
    workspace =
      opts
      |> Keyword.get(:workspace, %{})
      |> Map.new()
      |> Map.put_new(:policy, session_config.workspace_policy)

    context = %{
      prompt_profile: session_config.prompt_profile,
      session: %{
        profile_name: session_config.profile_name,
        provider: session_config.provider,
        model: session_config.model
      },
      workspace: workspace
    }

    case Keyword.get(opts, :capabilities) do
      capabilities when is_map(capabilities) and map_size(capabilities) > 0 ->
        Map.put(context, :capabilities, capabilities)

      _ ->
        context
    end
  end
end
