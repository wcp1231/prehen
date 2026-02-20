defmodule Prehen.Memory do
  @moduledoc """
  Two-tier memory 门面（STM + LTM adapter contract）。

  中文：
  - 提供 session 级 STM 读写（对话缓冲、工作上下文、token budget）。
  - 通过可插拔 LTM adapter 扩展长期记忆能力。
  - 读取策略为“STM 主，LTM 补充”，LTM 异常时降级不阻塞主流程。

  English:
  - Facade for two-tier memory (STM + pluggable LTM adapters).
  - Provides session-scoped STM updates (buffer/context/token budget).
  - Extends with adapter-based LTM without hard-coding a backend.
  - Uses STM-first reads; LTM failures degrade gracefully.
  """

  alias Prehen.Memory.{LTMAdapters, STM, STMProjector}
  alias Prehen.Memory.LTM.NoopAdapter

  @default_ltm_adapter_name :noop

  @type context :: %{
          session_id: String.t(),
          stm: STM.session_memory(),
          ltm: map() | nil,
          ltm_error: term() | nil,
          source: :stm_only | :stm_plus_ltm | :stm_ltm_degraded
        }

  @spec rebuild_session(String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def rebuild_session(session_id, records, opts \\ [])
      when is_binary(session_id) and is_list(records) and is_list(opts) do
    STMProjector.rebuild(session_id, records, stm_opts(opts))
  end

  @spec ensure_session(String.t(), keyword()) :: {:ok, STM.session_memory()}
  def ensure_session(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    STM.ensure_session(session_id, stm_opts(opts))
  end

  @spec put_working_context(String.t(), map(), keyword()) :: {:ok, STM.session_memory()}
  def put_working_context(session_id, context, opts \\ [])
      when is_binary(session_id) and is_map(context) and is_list(opts) do
    STM.put_working_context(session_id, context, stm_opts(opts))
  end

  @spec record_turn(String.t(), map(), keyword()) :: {:ok, map()}
  def record_turn(session_id, turn, opts \\ [])
      when is_binary(session_id) and is_map(turn) and is_list(opts) do
    with {:ok, stm} <- STM.record_turn(session_id, turn, stm_opts(opts)) do
      ltm_write = ltm_write(session_id, turn, stm, opts)
      {:ok, %{session_id: session_id, stm: stm, ltm_write: ltm_write}}
    end
  end

  @spec context(String.t(), keyword()) :: {:ok, context()}
  def context(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    with {:ok, stm} <- STM.ensure_session(session_id, stm_opts(opts)) do
      query = %{
        latest_turn: List.last(stm.conversation_buffer),
        working_context: stm.working_context,
        token_budget: stm.token_budget
      }

      case ltm_read(session_id, query, opts) do
        {:ok, nil} ->
          {:ok, base_context(session_id, stm, nil, nil, :stm_only)}

        {:ok, ltm_payload} ->
          {:ok, base_context(session_id, stm, ltm_payload, nil, :stm_plus_ltm)}

        {:error, reason} ->
          {:ok, base_context(session_id, stm, nil, reason, :stm_ltm_degraded)}
      end
    end
  end

  defp ltm_read(session_id, query, opts) do
    with {:ok, adapter} <- resolve_ltm_adapter(opts) do
      adapter.get(session_id, query)
    end
  end

  defp ltm_write(session_id, turn, stm, opts) do
    with {:ok, adapter} <- resolve_ltm_adapter(opts) do
      adapter.put(session_id, turn, %{
        token_budget: stm.token_budget,
        working_context: stm.working_context,
        at_ms: System.system_time(:millisecond)
      })
    end
  end

  defp resolve_ltm_adapter(opts) do
    explicit_adapter = Keyword.get(opts, :ltm_adapter)
    explicit_name = Keyword.get(opts, :ltm_adapter_name)

    cond do
      valid_adapter_module?(explicit_adapter) ->
        {:ok, explicit_adapter}

      is_atom(explicit_name) and not is_nil(explicit_name) ->
        fetch_ltm_adapter(explicit_name)

      valid_adapter_module?(Application.get_env(:prehen, :ltm_adapter)) ->
        {:ok, Application.get_env(:prehen, :ltm_adapter)}

      true ->
        Application.get_env(:prehen, :ltm_adapter_name, @default_ltm_adapter_name)
        |> normalize_adapter_name()
        |> fetch_ltm_adapter()
    end
  end

  defp fetch_ltm_adapter(name) when is_atom(name) do
    do_fetch_ltm_adapter(name)
  catch
    :exit, _ -> {:ok, NoopAdapter}
  end

  defp do_fetch_ltm_adapter(name) do
    case LTMAdapters.fetch(name) do
      {:ok, adapter} ->
        {:ok, adapter}

      {:error, :not_found} ->
        cond do
          valid_adapter_module?(name) -> {:ok, name}
          name == :noop -> {:ok, NoopAdapter}
          true -> {:error, {:ltm_adapter_not_found, name}}
        end
    end
  end

  defp valid_adapter_module?(adapter) when is_atom(adapter) do
    function_exported?(adapter, :get, 2) and function_exported?(adapter, :put, 3)
  end

  defp valid_adapter_module?(_), do: false

  defp normalize_adapter_name(nil), do: @default_ltm_adapter_name
  defp normalize_adapter_name(name), do: name

  defp stm_opts(opts) do
    opts
    |> Keyword.take([:buffer_limit, :token_budget_limit])
    |> Keyword.put_new_lazy(:buffer_limit, fn ->
      app_int(:stm_buffer_limit, 24)
    end)
    |> Keyword.put_new_lazy(:token_budget_limit, fn ->
      app_int(:stm_token_budget, 8_000)
    end)
  end

  defp app_int(key, fallback) do
    case Application.get_env(:prehen, key, fallback) do
      value when is_integer(value) and value > 0 -> value
      _ -> fallback
    end
  end

  defp base_context(session_id, stm, ltm, ltm_error, source) do
    %{
      session_id: session_id,
      stm: stm,
      ltm: ltm,
      ltm_error: ltm_error,
      source: source
    }
  end
end
