defmodule Prehen.Workspace.SessionQueue do
  @moduledoc false

  @type queue_kind :: :prompt | :steering | :follow_up
  @type item :: map()
  @type t :: %{
          prompt: :queue.queue(item()),
          steering: :queue.queue(item()),
          follow_up: :queue.queue(item())
        }

  @spec new() :: t()
  def new do
    %{
      prompt: :queue.new(),
      steering: :queue.new(),
      follow_up: :queue.new()
    }
  end

  @spec put(t(), queue_kind(), item()) :: t()
  def put(queue, :prompt, item), do: %{queue | prompt: :queue.in(item, queue.prompt)}
  def put(queue, :steering, item), do: %{queue | steering: :queue.in(item, queue.steering)}
  def put(queue, :follow_up, item), do: %{queue | follow_up: :queue.in(item, queue.follow_up)}

  @spec pop_next(t()) :: {:none, t()} | {item(), t()}
  def pop_next(queue) do
    cond do
      not :queue.is_empty(queue.steering) ->
        {{:value, item}, next} = :queue.out(queue.steering)
        {item, %{queue | steering: next}}

      not :queue.is_empty(queue.prompt) ->
        {{:value, item}, next} = :queue.out(queue.prompt)
        {item, %{queue | prompt: next}}

      not :queue.is_empty(queue.follow_up) ->
        {{:value, item}, next} = :queue.out(queue.follow_up)
        {item, %{queue | follow_up: next}}

      true ->
        {:none, queue}
    end
  end

  @spec sizes(t()) :: %{
          prompt: non_neg_integer(),
          steering: non_neg_integer(),
          follow_up: non_neg_integer()
        }
  def sizes(queue) do
    %{
      prompt: :queue.len(queue.prompt),
      steering: :queue.len(queue.steering),
      follow_up: :queue.len(queue.follow_up)
    }
  end

  @spec empty?(t()) :: boolean()
  def empty?(queue) do
    :queue.is_empty(queue.prompt) and :queue.is_empty(queue.steering) and
      :queue.is_empty(queue.follow_up)
  end
end
