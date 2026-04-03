defmodule Prehen.Home do
  @moduledoc false

  @default_dir ".prehen"

  @spec root() :: String.t()
  def root do
    System.get_env("PREHEN_HOME") || Path.join(System.user_home!(), @default_dir)
  end

  @spec path(String.t() | [String.t()]) :: String.t()
  def path(relative_path) when is_binary(relative_path), do: Path.join(root(), relative_path)
  def path(relative_path) when is_list(relative_path), do: Path.join([root() | relative_path])
end
