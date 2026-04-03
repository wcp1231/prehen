defmodule Prehen.Agents.Profile do
  @moduledoc false

  alias Prehen.Agents.Implementation

  @enforce_keys [:name]
  defstruct [
    :name,
    :label,
    :description,
    :implementation,
    :default_provider,
    :default_model,
    :prompt_profile,
    :workspace_policy,
    :command,
    :wrapper,
    args: [],
    env: %{},
    transport: :stdio,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t() | nil,
          description: String.t() | nil,
          implementation: String.t() | nil,
          default_provider: String.t() | nil,
          default_model: String.t() | nil,
          prompt_profile: String.t() | nil,
          workspace_policy: map() | nil,
          command: String.t() | [String.t()] | nil,
          wrapper: atom() | nil,
          args: [String.t()],
          env: map(),
          transport: atom(),
          metadata: map()
        }

  def bind_implementation(%__MODULE__{} = profile, %Implementation{} = implementation) do
    %__MODULE__{
      profile
      | command: implementation.command,
        args: implementation.args,
        env: implementation.env,
        wrapper: implementation.wrapper
    }
  end

  def bind_implementation(%__MODULE__{} = profile, implementation) when is_map(implementation) do
    %__MODULE__{
      profile
      | command: Map.get(implementation, :command),
        args: Map.get(implementation, :args, []),
        env: Map.get(implementation, :env, %{}),
        wrapper: Map.get(implementation, :wrapper)
    }
  end

  def display_name(%__MODULE__{label: label}) when is_binary(label) and label != "",
    do: label

  def display_name(%__MODULE__{name: name}), do: name

  def description(%__MODULE__{description: description}) when is_binary(description) do
    case String.trim(description) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def description(%__MODULE__{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get(:description, Map.get(metadata, "description"))
    |> normalize_optional_string()
  end

  def description(_profile), do: nil

  def id(%__MODULE__{name: name}), do: normalize_optional_string(name)

  def id(profile) when is_map(profile) do
    profile
    |> Map.get(:id, Map.get(profile, "id") || Map.get(profile, :name) || Map.get(profile, "name"))
    |> normalize_optional_string()
  end

  def id(_profile), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil
end
