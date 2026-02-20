defmodule Prehen.Memory.STM do
  @moduledoc """
  Session 级短期记忆（STM）存储。

  中文：
  - 每个 `session_id` 拥有独立内存快照，避免跨会话污染。
  - 核心数据包含：对话缓冲（conversation buffer）、工作上下文（working context）、
    token 预算（token budget）。
  - 支持按回合写入（`record_turn/3`）与上下文增量更新（`put_working_context/3`）。

  English:
  - Session-scoped short-term memory store.
  - Each `session_id` has an isolated memory snapshot.
  - Core data: conversation buffer, working context, and token budget.
  - Supports turn-based writes (`record_turn/3`) and context patch updates
    (`put_working_context/3`).
  """

  use GenServer

  @default_buffer_limit 24
  @default_token_budget_limit 8_000

  @typedoc """
  Token budget snapshot / token 预算快照。

  字段说明 / Fields:
  - `limit`: 预算上限 / maximum token budget for the session
  - `used`: 已使用估算 token / estimated tokens already consumed
  - `remaining`: 剩余可用 token / remaining estimated budget
  """
  @type token_budget :: %{
          limit: pos_integer(),
          used: non_neg_integer(),
          remaining: non_neg_integer()
        }

  @typedoc """
  Session STM 结构 / session short-term memory shape。

  字段说明 / Fields:
  - `conversation_buffer`:
    最近若干回合的上下文窗口（按 `buffer_limit` 截断）。
    Recent turns kept as the working context window (trimmed by `buffer_limit`).
  - `working_context`:
    与回合无关的会话工作状态（可增量 merge）。
    Session-level working state merged incrementally across turns.
  - `token_budget`:
    当前会话的 token 预算估算信息。
    Estimated token budget state for the session.
  - `buffer_limit`:
    对话缓冲最大回合数。
    Maximum number of turns retained in `conversation_buffer`.
  """
  @type session_memory :: %{
          conversation_buffer: [map()],
          working_context: map(),
          token_budget: token_budget(),
          buffer_limit: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  确保某个会话存在 STM 状态，不存在时按默认配置初始化。
  Ensure STM exists for a session, creating it with defaults if absent.
  """
  @spec ensure_session(String.t(), keyword()) :: {:ok, session_memory()}
  def ensure_session(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:ensure_session, session_id, opts})
  end

  @doc """
  写入一轮会话 turn，并更新 budget/working context。
  Record one turn and refresh budget/working context.
  """
  @spec record_turn(String.t(), map(), keyword()) :: {:ok, session_memory()}
  def record_turn(session_id, turn, opts \\ [])
      when is_binary(session_id) and is_map(turn) and is_list(opts) do
    GenServer.call(__MODULE__, {:record_turn, session_id, turn, opts})
  end

  @doc """
  增量更新 working context（浅层 merge）。
  Patch working context with shallow merge semantics.
  """
  @spec put_working_context(String.t(), map(), keyword()) :: {:ok, session_memory()}
  def put_working_context(session_id, context, opts \\ [])
      when is_binary(session_id) and is_map(context) and is_list(opts) do
    GenServer.call(__MODULE__, {:put_working_context, session_id, context, opts})
  end

  @spec put(String.t(), map()) :: :ok
  def put(session_id, payload) when is_binary(session_id) and is_map(payload) do
    GenServer.call(__MODULE__, {:put, session_id, payload})
  end

  @spec get(String.t()) :: {:ok, session_memory()} | {:error, :not_found}
  def get(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:get, session_id})
  end

  @impl true
  def init(_state) do
    {:ok,
     %{
       sessions: %{},
       default_buffer_limit: app_int(:stm_buffer_limit, @default_buffer_limit),
       default_token_budget_limit: app_int(:stm_token_budget, @default_token_budget_limit)
     }}
  end

  @impl true
  def handle_call({:put, session_id, payload}, _from, state) do
    memory =
      payload
      |> normalize_session_memory(state)
      |> enforce_buffer_limit()
      |> refresh_budget()

    next_sessions = Map.put(state.sessions, session_id, memory)
    {:reply, :ok, %{state | sessions: next_sessions}}
  end

  def handle_call({:ensure_session, session_id, opts}, _from, state) do
    {memory, next_state} = ensure_session_memory(state, session_id, opts)
    {:reply, {:ok, memory}, next_state}
  end

  def handle_call({:record_turn, session_id, turn, opts}, _from, state) do
    {memory, next_state} = ensure_session_memory(state, session_id, opts)
    buffer_limit = memory.buffer_limit

    next_memory =
      memory
      |> append_turn(normalize_turn(turn), buffer_limit)
      |> merge_working_context(map_get(turn, :working_context))
      |> refresh_budget()

    next_sessions = Map.put(next_state.sessions, session_id, next_memory)
    {:reply, {:ok, next_memory}, %{next_state | sessions: next_sessions}}
  end

  def handle_call({:put_working_context, session_id, context, opts}, _from, state) do
    {memory, next_state} = ensure_session_memory(state, session_id, opts)

    next_memory =
      memory
      |> merge_working_context(context)
      |> refresh_budget()

    next_sessions = Map.put(next_state.sessions, session_id, next_memory)
    {:reply, {:ok, next_memory}, %{next_state | sessions: next_sessions}}
  end

  def handle_call({:get, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, payload} -> {:reply, {:ok, payload}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  defp ensure_session_memory(state, session_id, opts) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, memory} ->
        {memory, state}

      :error ->
        memory =
          new_session_memory(
            Keyword.get(opts, :buffer_limit, state.default_buffer_limit),
            Keyword.get(opts, :token_budget_limit, state.default_token_budget_limit)
          )

        {memory, %{state | sessions: Map.put(state.sessions, session_id, memory)}}
    end
  end

  defp new_session_memory(buffer_limit, token_budget_limit) do
    normalized_buffer_limit = normalize_positive_int(buffer_limit, @default_buffer_limit)

    normalized_budget_limit =
      normalize_positive_int(token_budget_limit, @default_token_budget_limit)

    %{
      conversation_buffer: [],
      working_context: %{},
      token_budget: build_budget(normalized_budget_limit, 0),
      buffer_limit: normalized_buffer_limit
    }
  end

  defp normalize_session_memory(payload, state) do
    memory = new_session_memory(state.default_buffer_limit, state.default_token_budget_limit)

    %{
      conversation_buffer:
        payload
        |> map_get(:conversation_buffer, [])
        |> normalize_buffer(memory.buffer_limit),
      working_context:
        payload
        |> map_get(:working_context, %{})
        |> normalize_working_context(),
      token_budget:
        payload
        |> map_get(:token_budget, %{})
        |> normalize_budget(memory.token_budget.limit),
      buffer_limit:
        payload
        |> map_get(:buffer_limit, memory.buffer_limit)
        |> normalize_positive_int(memory.buffer_limit)
    }
  end

  defp normalize_buffer(buffer, _buffer_limit) when not is_list(buffer), do: []

  defp normalize_buffer(buffer, buffer_limit) do
    buffer
    |> Enum.filter(&is_map/1)
    |> keep_last(buffer_limit)
  end

  defp normalize_working_context(context) when is_map(context), do: context
  defp normalize_working_context(_), do: %{}

  defp normalize_budget(value, default_limit) when is_map(value) do
    limit = normalize_positive_int(map_get(value, :limit, default_limit), default_limit)
    used = normalize_non_neg_int(map_get(value, :used, 0), 0)
    build_budget(limit, used)
  end

  defp normalize_budget(_, default_limit), do: build_budget(default_limit, 0)

  defp append_turn(memory, turn, buffer_limit) do
    buffer =
      memory.conversation_buffer
      |> Kernel.++([turn])
      |> keep_last(buffer_limit)

    %{memory | conversation_buffer: buffer}
  end

  defp keep_last(items, limit) do
    count = length(items)

    if count > limit do
      Enum.drop(items, count - limit)
    else
      items
    end
  end

  defp merge_working_context(memory, context) when is_map(context) and map_size(context) > 0 do
    %{memory | working_context: Map.merge(memory.working_context, context)}
  end

  defp merge_working_context(memory, _), do: memory

  defp refresh_budget(memory) do
    used = estimate_token_usage(memory.conversation_buffer)
    limit = memory.token_budget.limit
    %{memory | token_budget: build_budget(limit, used)}
  end

  defp enforce_buffer_limit(memory) do
    buffer = keep_last(memory.conversation_buffer, memory.buffer_limit)
    %{memory | conversation_buffer: buffer}
  end

  defp build_budget(limit, used) do
    %{limit: limit, used: used, remaining: max(limit - used, 0)}
  end

  defp normalize_turn(turn) when is_map(turn) do
    turn
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp estimate_token_usage(value) when is_binary(value) do
    # rough token estimate for budget tracking without provider-specific tokenizer
    max(div(String.length(value), 4), 1)
  end

  defp estimate_token_usage(value) when is_number(value), do: 1
  defp estimate_token_usage(value) when is_atom(value), do: 1
  defp estimate_token_usage(value) when is_boolean(value), do: 1

  defp estimate_token_usage(value) when is_list(value) do
    Enum.reduce(value, 0, fn item, acc -> acc + estimate_token_usage(item) end)
  end

  defp estimate_token_usage(value) when is_map(value) do
    Enum.reduce(value, 0, fn {key, val}, acc ->
      acc + estimate_token_usage(key) + estimate_token_usage(val)
    end)
  end

  defp estimate_token_usage(_), do: 1

  defp map_get(map, key, default \\ nil)

  defp map_get(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp map_get(_, _key, default), do: default

  defp app_int(key, fallback) do
    case Application.get_env(:prehen, key, fallback) do
      value when is_integer(value) and value > 0 -> value
      _ -> fallback
    end
  end

  defp normalize_positive_int(value, _fallback) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value, fallback), do: fallback

  defp normalize_non_neg_int(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_int(_value, fallback), do: fallback
end
