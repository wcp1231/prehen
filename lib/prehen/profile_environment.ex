defmodule Prehen.ProfileEnvironment do
  @moduledoc false

  alias Prehen.Agents.Profile
  alias Prehen.Home

  defstruct [
    :profile,
    :profile_dir,
    :workspace_dir,
    :soul_md,
    :agents_md,
    :memory_dir,
    :global_skills_dir,
    :profile_skills_dir
  ]

  @type t :: %__MODULE__{
          profile: map() | struct(),
          profile_dir: String.t(),
          workspace_dir: String.t(),
          soul_md: String.t(),
          agents_md: String.t(),
          memory_dir: String.t(),
          global_skills_dir: String.t(),
          profile_skills_dir: String.t()
        }

  @spec load(map() | struct(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(profile, opts \\ []) do
    with {:ok, profile_id} <- profile_id(profile) do
      root = opts |> Keyword.get(:prehen_home) |> normalize_root()
      profile_dir = Path.join([root, "profiles", profile_id])
      profile_skills_dir = Path.join(profile_dir, "skills")
      memory_dir = Path.join(profile_dir, "memory")
      global_skills_dir = Path.join(root, "skills")

      with :ok <- ensure_dir(global_skills_dir),
           :ok <- ensure_dir(profile_dir),
           :ok <- ensure_dir(profile_skills_dir),
           :ok <- ensure_dir(memory_dir),
           {:ok, soul_md} <- read_optional(Path.join(profile_dir, "SOUL.md")),
           {:ok, agents_md} <- read_optional(Path.join(profile_dir, "AGENTS.md")) do
        {:ok,
         %__MODULE__{
           profile: profile,
           profile_dir: profile_dir,
           workspace_dir: profile_dir,
           soul_md: soul_md,
           agents_md: agents_md,
           memory_dir: memory_dir,
           global_skills_dir: global_skills_dir,
           profile_skills_dir: profile_skills_dir
         }}
      end
    end
  end

  defp profile_id(profile) do
    case Profile.id(profile) do
      nil -> {:error, :invalid_profile}
      profile_id -> {:ok, profile_id}
    end
  end

  defp normalize_root(nil), do: Home.root()
  defp normalize_root(root), do: Path.expand(root)

  defp ensure_dir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_optional(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end
end
