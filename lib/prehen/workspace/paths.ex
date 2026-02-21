defmodule Prehen.Workspace.Paths do
  @moduledoc false

  @default_mode 0o700

  @spec prehen_home() :: String.t()
  def prehen_home do
    home =
      System.get_env("PREHEN_HOME") ||
        System.user_home() ||
        "."

    Path.join(home, ".prehen")
  end

  @spec default_workspace_dir() :: String.t()
  def default_workspace_dir do
    Path.join(prehen_home(), "workspace")
  end

  @spec default_global_dir() :: String.t()
  def default_global_dir do
    Path.join(prehen_home(), "global")
  end

  @spec resolve_workspace_dir(keyword() | map()) :: String.t()
  def resolve_workspace_dir(opts_or_map \\ [])

  def resolve_workspace_dir(opts) when is_list(opts) do
    value =
      Keyword.get(opts, :workspace_dir) ||
        Keyword.get(opts, :workspace) ||
        Application.get_env(:prehen, :workspace_dir) ||
        System.get_env("PREHEN_WORKSPACE_DIR") ||
        default_workspace_dir()

    Path.expand(to_string(value))
  end

  def resolve_workspace_dir(%{} = map) do
    value =
      Map.get(map, :workspace_dir) ||
        Map.get(map, "workspace_dir") ||
        Map.get(map, :workspace) ||
        Map.get(map, "workspace") ||
        Application.get_env(:prehen, :workspace_dir) ||
        System.get_env("PREHEN_WORKSPACE_DIR") ||
        default_workspace_dir()

    Path.expand(to_string(value))
  end

  @spec resolve_global_dir(keyword() | map()) :: String.t()
  def resolve_global_dir(opts_or_map \\ [])

  def resolve_global_dir(opts) when is_list(opts) do
    value =
      Keyword.get(opts, :global_dir) ||
        Application.get_env(:prehen, :global_dir) ||
        System.get_env("PREHEN_GLOBAL_DIR") ||
        default_global_dir()

    Path.expand(to_string(value))
  end

  def resolve_global_dir(%{} = map) do
    value =
      Map.get(map, :global_dir) ||
        Map.get(map, "global_dir") ||
        Application.get_env(:prehen, :global_dir) ||
        System.get_env("PREHEN_GLOBAL_DIR") ||
        default_global_dir()

    Path.expand(to_string(value))
  end

  @spec prehen_dir(String.t()) :: String.t()
  def prehen_dir(workspace_dir) when is_binary(workspace_dir) do
    Path.join(Path.expand(workspace_dir), ".prehen")
  end

  @spec config_dir(String.t()) :: String.t()
  def config_dir(workspace_dir) when is_binary(workspace_dir) do
    Path.join(prehen_dir(workspace_dir), "config")
  end

  @spec sessions_dir(String.t()) :: String.t()
  def sessions_dir(workspace_dir) when is_binary(workspace_dir) do
    Path.join(prehen_dir(workspace_dir), "sessions")
  end

  @spec memory_dir(String.t()) :: String.t()
  def memory_dir(workspace_dir) when is_binary(workspace_dir) do
    Path.join(prehen_dir(workspace_dir), "memory")
  end

  @spec plugins_dir(String.t()) :: String.t()
  def plugins_dir(workspace_dir) when is_binary(workspace_dir) do
    Path.join(prehen_dir(workspace_dir), "plugins")
  end

  @spec tools_dir(String.t()) :: String.t()
  def tools_dir(workspace_dir) when is_binary(workspace_dir) do
    Path.join(prehen_dir(workspace_dir), "tools")
  end

  @spec skills_dir(String.t()) :: String.t()
  def skills_dir(workspace_dir) when is_binary(workspace_dir) do
    Path.join(prehen_dir(workspace_dir), "skills")
  end

  @spec global_config_dir(String.t()) :: String.t()
  def global_config_dir(global_dir) when is_binary(global_dir) do
    Path.join(Path.expand(global_dir), "config")
  end

  @spec global_plugins_dir(String.t()) :: String.t()
  def global_plugins_dir(global_dir) when is_binary(global_dir) do
    Path.join(Path.expand(global_dir), "plugins")
  end

  @spec global_tools_dir(String.t()) :: String.t()
  def global_tools_dir(global_dir) when is_binary(global_dir) do
    Path.join(Path.expand(global_dir), "tools")
  end

  @spec global_skills_dir(String.t()) :: String.t()
  def global_skills_dir(global_dir) when is_binary(global_dir) do
    Path.join(Path.expand(global_dir), "skills")
  end

  @spec ensure_workspace_layout(String.t()) :: :ok | {:error, term()}
  def ensure_workspace_layout(workspace_dir) when is_binary(workspace_dir) do
    workspace = Path.expand(workspace_dir)
    prehen = prehen_dir(workspace)

    with :ok <- File.mkdir_p(workspace),
         :ok <- ensure_dir(prehen),
         :ok <- ensure_dir(config_dir(workspace)),
         :ok <- ensure_dir(sessions_dir(workspace)),
         :ok <- ensure_dir(memory_dir(workspace)),
         :ok <- ensure_dir(plugins_dir(workspace)),
         :ok <- ensure_dir(tools_dir(workspace)),
         :ok <- ensure_dir(skills_dir(workspace)) do
      :ok
    end
  end

  @spec ensure_global_layout(String.t()) :: :ok | {:error, term()}
  def ensure_global_layout(global_dir) when is_binary(global_dir) do
    root = Path.expand(global_dir)

    with :ok <- ensure_dir(root),
         :ok <- ensure_dir(global_config_dir(root)),
         :ok <- ensure_dir(global_plugins_dir(root)),
         :ok <- ensure_dir(global_tools_dir(root)),
         :ok <- ensure_dir(global_skills_dir(root)) do
      :ok
    end
  end

  defp ensure_dir(path) do
    with :ok <- File.mkdir_p(path),
         :ok <- ensure_mode(path, @default_mode) do
      :ok
    end
  end

  defp ensure_mode(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
      {:error, :eperm} -> :ok
      {:error, reason} -> {:error, {:workspace_mode_failed, path, reason}}
    end
  end
end
