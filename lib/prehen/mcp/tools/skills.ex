defmodule Prehen.MCP.Tools.Skills do
  @moduledoc false

  alias Prehen.Home

  @spec search(map(), map()) :: {:ok, map()}
  def search(context, args) when is_map(context) and is_map(args) do
    query = normalize_query(Map.get(args, "query") || Map.get(args, :query))

    skills =
      context
      |> visible_skills()
      |> Enum.filter(&matches?(&1, query))
      |> Enum.map(&search_result/1)

    {:ok, %{"skills" => skills}}
  end

  def search(context, _args), do: search(context, %{})

  @spec load(map(), map()) :: {:ok, map()} | {:error, :not_found}
  def load(context, %{"id" => id}) when is_map(context) and is_binary(id) and id != "" do
    with {:ok, skill} <- fetch_visible_skill(context, id),
         {:ok, body} <- File.read(skill.path) do
      {:ok,
       %{
         "id" => skill.id,
         "name" => skill.name,
         "summary" => skill.summary,
         "scope" => skill.scope,
         "body" => body
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def load(context, %{id: id}) when is_map(context) and is_binary(id) and id != "" do
    load(context, %{"id" => id})
  end

  def load(_context, _args), do: {:error, :not_found}

  defp fetch_visible_skill(context, id) do
    case Enum.find(visible_skills(context), &(&1.id == id)) do
      nil -> {:error, :not_found}
      skill -> {:ok, skill}
    end
  end

  defp visible_skills(context) do
    root = prehen_home(context)

    global_skills = scan_dir(Path.join(root, "skills"), "global", "global")

    profile_skills =
      case profile_id(context) do
        nil ->
          []

        profile_id ->
          scan_dir(
            Path.join([root, "profiles", profile_id, "skills"]),
            "profile",
            "profile:#{profile_id}"
          )
      end

    Enum.sort_by(global_skills ++ profile_skills, & &1.id)
  end

  defp scan_dir(path, scope, id_prefix) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          full_path = Path.join(path, entry)

          if File.regular?(full_path) and String.ends_with?(entry, ".md") do
            case build_skill(full_path, entry, scope, id_prefix) do
              {:ok, skill} -> [skill]
              {:error, _reason} -> []
            end
          else
            []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp build_skill(path, filename, scope, id_prefix) do
    slug = Path.rootname(filename)

    case File.read(path) do
      {:ok, body} ->
        {:ok,
         %{
           id: "#{id_prefix}:#{slug}",
           name: skill_name(body, slug),
           summary: skill_summary(body),
           scope: scope,
           path: path
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp search_result(skill) do
    %{
      "id" => skill.id,
      "name" => skill.name,
      "summary" => skill.summary,
      "scope" => skill.scope
    }
  end

  defp matches?(_skill, ""), do: true

  defp matches?(skill, query) do
    haystack =
      [skill.id, skill.name, skill.summary]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> String.downcase()

    String.contains?(haystack, query)
  end

  defp skill_name(body, fallback) do
    body
    |> String.split("\n")
    |> Enum.find_value(fallback, fn
      "# " <> title ->
        case String.trim(title) do
          "" -> nil
          trimmed -> trimmed
        end

      _line ->
        nil
    end)
  end

  defp skill_summary(body) do
    body
    |> String.split("\n")
    |> Enum.find_value("", fn line ->
      case Regex.run(~r/^summary:\s*(.+)$/i, line, capture: :all_but_first) do
        [summary] -> String.trim(summary)
        _ -> nil
      end
    end)
  end

  defp normalize_query(query) when is_binary(query), do: query |> String.trim() |> String.downcase()
  defp normalize_query(_query), do: ""

  defp prehen_home(context) do
    Map.get(context, :prehen_home) || Map.get(context, "prehen_home") || Home.root()
  end

  defp profile_id(context) do
    Map.get(context, :profile_id) || Map.get(context, "profile_id")
  end
end
