defmodule Prehen.Actions.PathGuard do
  @moduledoc false

  @spec resolve(term(), map()) :: {:ok, String.t()} | {:error, map()}
  def resolve(nil, _config), do: {:error, error("validation_error", "missing path")}
  def resolve("", _config), do: {:error, error("validation_error", "empty path")}

  def resolve(path, config) when is_binary(path) do
    workspace_dir = resolve_workspace_dir(config)
    expanded = expand_path(path, workspace_dir)

    if inside_root?(expanded, workspace_dir) do
      {:ok, expanded}
    else
      {:error, error("permission_error", "path is outside workspace", %{path: path})}
    end
  end

  def resolve(_path, _config), do: {:error, error("validation_error", "path must be a string")}

  defp expand_path(path, base_dir) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _ -> Path.expand(path, base_dir)
    end
  end

  defp inside_root?(path, root) do
    normalized_path = Path.expand(path)
    normalized_root = Path.expand(root)

    normalized_path == normalized_root ||
      String.starts_with?(normalized_path, normalized_root <> "/")
  end

  defp resolve_workspace_dir(config) when is_map(config) do
    config[:workspace_dir] || config["workspace_dir"] || "."
  end

  defp error(type, message, details \\ %{}) do
    %{"type" => type, "message" => message, "details" => details}
  end
end
