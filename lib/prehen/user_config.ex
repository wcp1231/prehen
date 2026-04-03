defmodule Prehen.UserConfig do
  @moduledoc false

  alias Prehen.Home

  @spec empty() :: map()
  def empty do
    %{profiles: [], providers: %{}, channels: %{}}
  end

  @spec load(keyword()) :: {:ok, map()} | {:error, term()}
  def load(opts \\ []) do
    opts
    |> Keyword.get(:root, Home.root())
    |> Path.join("config.yaml")
    |> YamlElixir.read_from_file()
    |> case do
      {:ok, data} -> {:ok, normalize(data)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize(term()) :: map()
  def normalize(data) when is_map(data) do
    %{
      profiles: normalize_profiles(fetch_attr(data, :profiles)),
      providers: normalize_named_map(fetch_attr(data, :providers)),
      channels: normalize_named_map(fetch_attr(data, :channels))
    }
  end

  def normalize(_data), do: empty()

  defp normalize_profiles(profiles) when is_list(profiles) do
    Enum.map(profiles, &normalize_profile/1)
  end

  defp normalize_profiles(_profiles), do: []

  defp normalize_profile(profile) when is_map(profile) do
    %{
      id: normalize_optional_string(fetch_attr(profile, :id)),
      label: normalize_optional_string(fetch_attr(profile, :label)),
      description: normalize_optional_string(fetch_attr(profile, :description)),
      runtime: normalize_optional_string(fetch_attr(profile, :runtime)),
      default_provider: normalize_optional_string(fetch_attr(profile, :default_provider)),
      default_model: normalize_optional_string(fetch_attr(profile, :default_model)),
      enabled: normalize_enabled(fetch_attr(profile, :enabled))
    }
  end

  defp normalize_profile(_profile) do
    %{
      id: nil,
      label: nil,
      description: nil,
      runtime: nil,
      default_provider: nil,
      default_model: nil,
      enabled: true
    }
  end

  defp normalize_named_map(values) when is_map(values) do
    Map.new(values, fn {key, value} ->
      {to_string(key), stringify_keys(value)}
    end)
  end

  defp normalize_named_map(_values), do: %{}

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), stringify_keys(nested_value)}
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp fetch_attr(attrs, key) do
    if Map.has_key?(attrs, key) do
      Map.get(attrs, key)
    else
      Map.get(attrs, Atom.to_string(key))
    end
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_atom(value), do: to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp normalize_enabled(value) when value in [true, false], do: value
  defp normalize_enabled(value) when value in ["true", "TRUE", "yes", "YES", "1"], do: true
  defp normalize_enabled(value) when value in ["false", "FALSE", "no", "NO", "0"], do: false
  defp normalize_enabled(_value), do: true
end
