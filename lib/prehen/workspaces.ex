defmodule Prehen.Workspaces do
  @moduledoc false

  @base_dir_name "prehen_sessions"

  @spec resolve(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(workspace, profile_name) do
    case normalize_optional_string(workspace) do
      nil -> allocate(profile_name)
      path -> ensure_workspace(path)
    end
  end

  @spec allocate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def allocate(profile_name) do
    profile_segment =
      profile_name
      |> normalize_optional_string()
      |> sanitize_segment()

    workspace =
      base_dir()
      |> Path.join(@base_dir_name)
      |> Path.join("#{profile_segment}_#{System.unique_integer([:positive])}")
      |> Path.expand()

    ensure_workspace(workspace)
  end

  defp ensure_workspace(path) when is_binary(path) do
    case File.mkdir_p(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_dir do
    System.tmp_dir() || File.cwd!()
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp sanitize_segment(nil), do: "session"

  defp sanitize_segment(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "_")
    |> case do
      "" -> "session"
      sanitized -> sanitized
    end
  end
end
