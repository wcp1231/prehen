defmodule Prehen.Agents.SessionConfig do
  @moduledoc false

  @enforce_keys [:profile_name, :provider, :model, :prompt_profile]
  defstruct [:profile_name, :provider, :model, :prompt_profile, :workspace_policy]

  @type t :: %__MODULE__{
          profile_name: String.t(),
          provider: String.t(),
          model: String.t(),
          prompt_profile: String.t(),
          workspace_policy: map() | nil
        }
end
