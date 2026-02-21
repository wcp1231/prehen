defmodule Prehen.Actions.LS do
  @moduledoc false

  alias Prehen.Actions.PathGuard

  use Jido.Action,
    name: "ls",
    description: "List directory entries in the allowed workspace root.",
    schema: [
      path: [type: :string, required: false, default: "."]
    ]

  @impl true
  def run(params, context) do
    config = tool_config(context)
    path = Map.get(params, :path) || Map.get(params, "path") || "."

    case invoke(%{"path" => path}, config) do
      %{"ok" => true, "data" => data} -> {:ok, data}
      %{"ok" => false, "error" => error} -> {:error, error}
    end
  end

  @spec invoke(map(), map()) :: map()
  def invoke(args, config) do
    try do
      path = Map.get(args, "path") || Map.get(args, :path) || "."

      with {:ok, resolved} <- PathGuard.resolve(path, config),
           true <- File.dir?(resolved) do
        entries =
          resolved
          |> File.ls!()
          |> Enum.sort()
          |> Enum.map(fn name ->
            full = Path.join(resolved, name)
            kind = if File.dir?(full), do: "dir", else: "file"
            size = if kind == "file", do: File.stat!(full).size, else: nil
            %{"name" => name, "type" => kind, "size" => size}
          end)

        ok(%{"path" => resolved, "entries" => entries})
      else
        false ->
          error("validation_error", "path is not a directory", %{"path" => path})

        {:error, details} ->
          error(details["type"], details["message"], details["details"])
      end
    rescue
      e -> error("io_error", Exception.message(e))
    end
  end

  defp tool_config(context) do
    tool_context = context[:tool_context] || %{}

    %{
      workspace_dir:
        Map.get(tool_context, :workspace_dir) || Map.get(tool_context, "workspace_dir") || ".",
      read_max_bytes:
        Map.get(tool_context, :read_max_bytes) || Map.get(tool_context, "read_max_bytes") || 8_192
    }
  end

  defp ok(data), do: %{"ok" => true, "data" => data}

  defp error(type, message, details \\ %{}) do
    %{"ok" => false, "error" => %{"type" => type, "message" => message, "details" => details}}
  end
end
