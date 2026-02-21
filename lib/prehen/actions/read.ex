defmodule Prehen.Actions.Read do
  @moduledoc false

  alias Prehen.Actions.PathGuard

  use Jido.Action,
    name: "read",
    description: "Read text content from a file in the allowed workspace root.",
    schema: [
      path: [type: :string, required: true],
      start_line: [type: :integer, required: false],
      end_line: [type: :integer, required: false],
      max_bytes: [type: :integer, required: false]
    ]

  @impl true
  def run(params, context) do
    config = tool_config(context)

    args =
      %{
        "path" => Map.get(params, :path) || Map.get(params, "path"),
        "start_line" => Map.get(params, :start_line) || Map.get(params, "start_line"),
        "end_line" => Map.get(params, :end_line) || Map.get(params, "end_line"),
        "max_bytes" => Map.get(params, :max_bytes) || Map.get(params, "max_bytes")
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case invoke(args, config) do
      %{"ok" => true, "data" => data} -> {:ok, data}
      %{"ok" => false, "error" => error} -> {:error, error}
    end
  end

  @spec invoke(map(), map()) :: map()
  def invoke(args, config) do
    try do
      path = Map.get(args, "path") || Map.get(args, :path)

      with {:ok, resolved} <- PathGuard.resolve(path, config),
           true <- File.regular?(resolved),
           {:ok, content} <- File.read(resolved),
           true <- String.valid?(content) do
        start_line =
          parse_positive_int(Map.get(args, "start_line") || Map.get(args, :start_line), 1)

        end_line = parse_positive_int(Map.get(args, "end_line") || Map.get(args, :end_line), nil)

        max_bytes =
          parse_positive_int(
            Map.get(args, "max_bytes") || Map.get(args, :max_bytes),
            config[:read_max_bytes]
          )

        snippet = slice_lines(content, start_line, end_line)
        {snippet, truncated} = truncate(snippet, max_bytes)

        ok(%{
          "path" => resolved,
          "content" => snippet,
          "start_line" => start_line,
          "end_line" => end_line,
          "truncated" => truncated,
          "bytes" => byte_size(snippet)
        })
      else
        false ->
          error("validation_error", "file is not readable text")

        {:error, :enoent} ->
          error("io_error", "file does not exist", %{"path" => path})

        {:error, reason} when is_atom(reason) ->
          error("io_error", Atom.to_string(reason), %{"path" => path})

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

  defp slice_lines(content, start_line, nil) do
    content
    |> String.split("\n", trim: false)
    |> Enum.drop(start_line - 1)
    |> Enum.join("\n")
  end

  defp slice_lines(content, start_line, end_line) do
    length = max(end_line - start_line + 1, 0)

    content
    |> String.split("\n", trim: false)
    |> Enum.drop(start_line - 1)
    |> Enum.take(length)
    |> Enum.join("\n")
  end

  defp truncate(content, max_bytes) when byte_size(content) <= max_bytes, do: {content, false}
  defp truncate(content, max_bytes), do: {:binary.part(content, 0, max_bytes), true}

  defp parse_positive_int(nil, default), do: default

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0,
    do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_positive_int(_, default), do: default

  defp ok(data), do: %{"ok" => true, "data" => data}

  defp error(type, message, details \\ %{}) do
    %{"ok" => false, "error" => %{"type" => type, "message" => message, "details" => details}}
  end
end
