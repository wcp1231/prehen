defmodule Prehen.Test.MockBackend do
  @behaviour Prehen.Agent.Backend

  def start_link do
    case Process.whereis(__MODULE__) do
      nil -> Agent.start_link(fn -> [] end, name: __MODULE__)
      _pid -> {:ok, __MODULE__}
    end
  end

  def set_results(results) when is_list(results) do
    start_link()
    Agent.update(__MODULE__, fn _ -> results end)
  end

  @impl true
  def run(_task, _config) do
    start_link()

    Agent.get_and_update(__MODULE__, fn
      [head | tail] -> {head, tail}
      [] -> {{:error, %{status: :error, reason: :no_mock_result, trace: []}}, []}
    end)
  end
end

defmodule Prehen.Test.FakeSessionAdapter do
  @behaviour Prehen.Agent.Session.Adapter

  @impl true
  def start_agent(config) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          config: config,
          requests: %{},
          active_id: nil
        }
      end)

    {:ok, %{pid: pid}}
  end

  @impl true
  def stop_agent(%{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Agent.stop(pid, :normal)
    :ok
  end

  @impl true
  def ask(%{pid: pid}, query, opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    call_id = "llm_#{request_id}"
    now = System.monotonic_time(:millisecond)

    request = %{
      id: request_id,
      call_id: call_id,
      query: query,
      started_at: now,
      delay_ms: request_delay(query),
      model_exhausted?: String.contains?(query, "fallback-exhausted"),
      cancelled?: false,
      completed?: false
    }

    Agent.update(pid, fn state ->
      state
      |> put_in([:requests, request_id], request)
      |> Map.put(:active_id, request_id)
    end)

    {:ok, %{id: request_id}}
  end

  @impl true
  def await(%{pid: pid}, %{id: request_id}, opts) do
    timeout_ms = Keyword.get(opts, :timeout, 1_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(pid, request_id, deadline)
  end

  @impl true
  def cancel(%{pid: pid}, opts) do
    request_id = Keyword.get(opts, :request_id)

    Agent.update(pid, fn state ->
      if is_binary(request_id) and state.requests[request_id] do
        put_in(state, [:requests, request_id, :cancelled?], true)
      else
        state
      end
    end)

    :ok
  end

  @impl true
  def steer(agent, opts), do: cancel(agent, opts)

  @impl true
  def follow_up(_agent, _query, _opts), do: :ok

  @impl true
  def status(%{pid: pid}) do
    state = Agent.get(pid, & &1)

    case state.active_id do
      nil ->
        {:ok, idle_snapshot()}

      request_id ->
        request = Map.fetch!(state.requests, request_id)
        elapsed_ms = System.monotonic_time(:millisecond) - request.started_at

        if request.completed? do
          {:ok, idle_snapshot()}
        else
          tool_calls = tool_calls_for(request, elapsed_ms)
          model_events = model_events_for(request, elapsed_ms)

          details = %{
            current_llm_call_id: request.call_id,
            streaming_text: streaming_text_for(elapsed_ms),
            thinking_trace: thinking_trace_for(request, elapsed_ms),
            tool_calls: tool_calls,
            model_events: model_events,
            iteration: 1,
            active_request_id: request.id
          }

          {:ok,
           %{
             snapshot: %{
               status: :running,
               done?: false,
               result: nil,
               details: details
             },
             raw_state: %{active_request_id: request.id}
           }}
        end
    end
  end

  defp do_await(pid, request_id, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      request = Agent.get(pid, &get_in(&1, [:requests, request_id]))

      cond do
        is_nil(request) ->
          {:error, :not_found}

        request.cancelled? ->
          mark_completed(pid, request_id)
          {:error, {:cancelled, :steering}}

        now - request.started_at >= request.delay_ms ->
          mark_completed(pid, request_id)

          if request.model_exhausted? do
            {:error, {:provider_error, :timeout}}
          else
            {:ok, "answer:#{request.query}"}
          end

        true ->
          Process.sleep(10)
          do_await(pid, request_id, deadline)
      end
    end
  end

  defp mark_completed(pid, request_id) do
    Agent.update(pid, fn state ->
      state
      |> put_in([:requests, request_id, :completed?], true)
      |> Map.put(:active_id, nil)
    end)
  end

  defp request_delay(query) do
    if String.contains?(query, "slow"), do: 180, else: 100
  end

  defp streaming_text_for(elapsed_ms) do
    cond do
      elapsed_ms < 30 -> "a"
      elapsed_ms < 60 -> "ab"
      true -> "abc"
    end
  end

  defp thinking_trace_for(request, elapsed_ms) do
    if elapsed_ms >= 40 do
      [%{call_id: request.call_id, iteration: 1, thinking: "thinking"}]
    else
      []
    end
  end

  defp tool_calls_for(request, elapsed_ms) do
    tool_id = "tool_#{request.id}"

    cond do
      elapsed_ms < 70 ->
        []

      elapsed_ms < 110 ->
        [%{id: tool_id, name: "ls", arguments: %{"path" => "."}, status: :running, result: nil}]

      true ->
        [
          %{
            id: tool_id,
            name: "ls",
            arguments: %{"path" => "."},
            status: :completed,
            result: {:ok, %{"path" => ".", "entries" => []}}
          }
        ]
    end
  end

  defp model_events_for(%{model_exhausted?: false}, _elapsed_ms), do: []

  defp model_events_for(request, elapsed_ms) do
    selected = %{kind: :selected, call_id: request.call_id, model: "openai:gpt-5-mini"}

    cond do
      elapsed_ms < 40 ->
        [selected]

      elapsed_ms < 80 ->
        [
          selected,
          %{
            kind: :fallback,
            call_id: request.call_id,
            from_model: "openai:gpt-5-mini",
            to_model: "openai:gpt-5",
            error_type: :timeout
          }
        ]

      true ->
        [
          selected,
          %{
            kind: :fallback,
            call_id: request.call_id,
            from_model: "openai:gpt-5-mini",
            to_model: "openai:gpt-5",
            error_type: :timeout
          },
          %{
            kind: :exhausted,
            call_id: request.call_id,
            model: "openai:gpt-5",
            error_type: :provider_error
          }
        ]
    end
  end

  defp idle_snapshot do
    %{
      snapshot: %{
        status: :idle,
        done?: true,
        result: nil,
        details: %{}
      },
      raw_state: %{}
    }
  end
end

defmodule PrehenWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      import Phoenix.ChannelTest
      alias PrehenWeb.Endpoint

      @endpoint PrehenWeb.Endpoint
    end
  end
end

unless Code.ensure_loaded?(Prehen.Agents.Profile) do
  defmodule Prehen.Agents.Profile do
    defstruct [:name, :command]
  end
end

workspace_dir =
  Path.join(System.tmp_dir!(), "prehen_test_workspace_#{System.unique_integer([:positive])}")

global_dir =
  Path.join(System.tmp_dir!(), "prehen_test_global_#{System.unique_integer([:positive])}")

File.mkdir_p!(workspace_dir)
File.mkdir_p!(global_dir)
Application.put_env(:prehen, :workspace_dir, workspace_dir)
Application.put_env(:prehen, :global_dir, global_dir)

ExUnit.after_suite(fn _ ->
  Application.delete_env(:prehen, :workspace_dir)
  Application.delete_env(:prehen, :global_dir)
  File.rm_rf(workspace_dir)
  File.rm_rf(global_dir)
end)

ExUnit.start()
