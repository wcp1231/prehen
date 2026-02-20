defmodule Prehen.Conversation.SessionLedger do
  @moduledoc false

  @default_dir "./.prehen/sessions"
  @default_dir_mode 0o700
  @default_file_mode 0o600

  @top_level_atom_keys %{
    "aborted" => :aborted,
    "answer" => :answer,
    "arguments" => :arguments,
    "at_ms" => :at_ms,
    "call_id" => :call_id,
    "chunk_type" => :chunk_type,
    "content" => :content,
    "delta" => :delta,
    "error" => :error,
    "input" => :input,
    "iteration" => :iteration,
    "kind" => :kind,
    "message_kind" => :message_kind,
    "outcome" => :outcome,
    "partial" => :partial,
    "phase" => :phase,
    "query" => :query,
    "reason" => :reason,
    "request_id" => :request_id,
    "result" => :result,
    "role" => :role,
    "run_id" => :run_id,
    "schema_version" => :schema_version,
    "seq" => :seq,
    "session_id" => :session_id,
    "source" => :source,
    "status" => :status,
    "stored_at_ms" => :stored_at_ms,
    "tool_calls" => :tool_calls,
    "tool_name" => :tool_name,
    "turn_id" => :turn_id,
    "type" => :type,
    "working_context" => :working_context
  }

  @required_fields [:session_id, :seq, :kind, :at_ms, :stored_at_ms]

  @spec ledger_dir() :: String.t()
  def ledger_dir do
    dir =
      case Application.get_env(:prehen, :session_ledger_dir) do
        nil -> System.get_env("PREHEN_SESSION_LEDGER_DIR") || @default_dir
        value -> value
      end

    dir
    |> Path.expand()
  end

  @spec session_file(String.t()) :: String.t()
  def session_file(session_id) when is_binary(session_id) do
    Path.join(ledger_dir(), "#{session_id}.jsonl")
  end

  @spec session_exists?(String.t()) :: boolean()
  def session_exists?(session_id) when is_binary(session_id) do
    File.exists?(session_file(session_id))
  end

  @spec ensure_session_file(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_session_file(session_id) when is_binary(session_id) do
    path = session_file(session_id)

    with :ok <- ensure_directory(),
         :ok <- ensure_file(path),
         :ok <- ensure_mode(path, file_mode()) do
      {:ok, path}
    end
  end

  @spec append(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def append(session_id, record) when is_binary(session_id) and is_map(record) do
    with {:ok, path} <- ensure_session_file(session_id),
         {:ok, encoded} <- encode_record(record),
         :ok <- File.write(path, encoded <> "\n", [:append, :binary]) do
      {:ok, record}
    else
      {:error, reason} -> {:error, {:ledger_write_failed, reason}}
    end
  rescue
    error -> {:error, {:ledger_write_failed, Exception.message(error)}}
  end

  @spec sync(String.t()) :: :ok | {:error, term()}
  def sync(session_id) when is_binary(session_id) do
    with {:ok, path} <- ensure_session_file(session_id),
         {:ok, io} <- :file.open(to_charlist(path), [:append, :raw, :binary]),
         :ok <- :file.sync(io),
         :ok <- :file.close(io) do
      :ok
    else
      {:error, reason} -> {:error, {:ledger_sync_failed, reason}}
      reason -> {:error, {:ledger_sync_failed, reason}}
    end
  rescue
    error -> {:error, {:ledger_sync_failed, Exception.message(error)}}
  end

  @spec replay(String.t()) :: {:ok, [map()]} | {:error, term()}
  def replay(session_id) when is_binary(session_id) do
    path = session_file(session_id)

    cond do
      not File.exists?(path) ->
        {:ok, []}

      true ->
        with {:ok, records} <- parse_records(path),
             {:ok, sorted_records} <- validate_records(records, session_id) do
          {:ok, sorted_records}
        end
    end
  end

  defp parse_records(path) do
    path
    |> File.stream!([], :line)
    |> Stream.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, line_no}, {:ok, acc} ->
      trimmed = String.trim(line)

      if trimmed == "" do
        {:cont, {:ok, acc}}
      else
        with {:ok, raw} <- decode_json(trimmed, line_no),
             {:ok, record} <- decode_record(raw, line_no) do
          {:cont, {:ok, [record | acc]}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:ledger_read_failed, Exception.message(error)}}
  end

  defp decode_json(payload, line_no) do
    case Jason.decode(payload) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, {:ledger_corrupt, %{line: line_no, reason: reason}}}
    end
  end

  defp decode_record(raw, line_no) do
    case decode_term(raw) do
      {:ok, record} ->
        if is_map(record) do
          {:ok, record}
        else
          {:error, {:ledger_corrupt, %{line: line_no, reason: :invalid_record_shape}}}
        end

      {:error, reason} ->
        {:error, {:ledger_corrupt, %{line: line_no, reason: reason}}}
    end
  end

  defp validate_records(records, session_id) when is_list(records) do
    with :ok <- validate_required_fields(records),
         :ok <- validate_session_ids(records, session_id),
         :ok <- validate_sequence(records) do
      {:ok, Enum.sort_by(records, &map_get(&1, :seq, 0))}
    end
  end

  defp validate_required_fields(records) do
    case Enum.find(records, fn record ->
           Enum.any?(@required_fields, fn field -> is_nil(map_get(record, field)) end)
         end) do
      nil -> :ok
      _record -> {:error, {:ledger_corrupt, %{reason: :missing_required_fields}}}
    end
  end

  defp validate_session_ids(records, session_id) do
    case Enum.find(records, fn record -> map_get(record, :session_id) != session_id end) do
      nil -> :ok
      _record -> {:error, {:ledger_corrupt, %{reason: :session_id_mismatch}}}
    end
  end

  defp validate_sequence(records) do
    seqs =
      records
      |> Enum.map(&map_get(&1, :seq))
      |> Enum.sort()

    cond do
      seqs == [] ->
        :ok

      Enum.any?(seqs, fn seq -> not (is_integer(seq) and seq > 0) end) ->
        {:error, {:ledger_corrupt, %{reason: :invalid_seq}}}

      hd(seqs) != 1 ->
        {:error, {:ledger_corrupt, %{reason: :seq_must_start_at_one}}}

      seqs != Enum.to_list(1..length(seqs)) ->
        {:error, {:ledger_corrupt, %{reason: :non_contiguous_seq}}}

      true ->
        :ok
    end
  end

  defp ensure_directory do
    with :ok <- File.mkdir_p(ledger_dir()),
         :ok <- ensure_mode(ledger_dir(), dir_mode()) do
      :ok
    end
  end

  defp ensure_file(path) do
    with {:ok, io} <- File.open(path, [:append, :binary]),
         :ok <- File.close(io) do
      :ok
    end
  end

  defp ensure_mode(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
      {:error, :eperm} -> :ok
      {:error, reason} -> {:error, {:ledger_mode_failed, path, reason}}
    end
  end

  defp dir_mode do
    Application.get_env(:prehen, :session_ledger_dir_mode, @default_dir_mode)
  end

  defp file_mode do
    Application.get_env(:prehen, :session_ledger_file_mode, @default_file_mode)
  end

  defp encode_record(record) do
    record
    |> encode_term()
    |> Jason.encode()
  rescue
    error -> {:error, {:ledger_encode_failed, Exception.message(error)}}
  end

  defp encode_term(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, val} ->
      {encode_key(key), encode_term(val)}
    end)
  end

  defp encode_term(value) when is_list(value), do: Enum.map(value, &encode_term/1)

  defp encode_term(value) when is_tuple(value) do
    %{"$tuple" => value |> Tuple.to_list() |> Enum.map(&encode_term/1)}
  end

  defp encode_term(value) when is_atom(value) do
    if value in [true, false, nil] do
      value
    else
      %{"$atom" => Atom.to_string(value)}
    end
  end

  defp encode_term(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp encode_term(value), do: %{"$inspect" => inspect(value)}

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key) when is_binary(key), do: key
  defp encode_key(key), do: inspect(key)

  defp decode_term(%{"$tuple" => values}) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case decode_term(value) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> List.to_tuple()}
      {:error, _reason} = error -> error
    end
  end

  defp decode_term(%{"$atom" => value}) when is_binary(value),
    do: {:ok, maybe_existing_atom(value)}

  defp decode_term(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, val}, {:ok, acc} ->
      with {:ok, decoded_val} <- decode_term(val) do
        {:cont, {:ok, Map.put(acc, decode_key(key), decoded_val)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp decode_term(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case decode_term(item) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_term(value), do: {:ok, value}

  defp decode_key(key) when is_binary(key), do: Map.get(@top_level_atom_keys, key, key)
  defp decode_key(key), do: key

  defp maybe_existing_atom(value) do
    normalized = String.trim(value)

    try do
      String.to_existing_atom(normalized)
    rescue
      ArgumentError -> normalized
    end
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp map_get(_, _key, default), do: default
end
