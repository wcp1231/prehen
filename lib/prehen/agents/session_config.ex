defmodule Prehen.Agents.SessionConfig do
  @moduledoc false

  @enforce_keys [:profile_name, :provider, :model, :prompt_profile]
  defstruct [
    :profile_name,
    :provider,
    :model,
    :prompt_profile,
    :workspace_policy,
    :implementation,
    :workspace,
    :profile_dir,
    :system_prompt
  ]

  @type t :: %__MODULE__{
          profile_name: String.t(),
          provider: String.t(),
          model: String.t(),
          prompt_profile: String.t(),
          workspace_policy: map() | nil,
          implementation: module() | struct() | map() | nil,
          workspace: String.t() | nil,
          profile_dir: String.t() | nil,
          system_prompt: String.t() | nil
        }
end
