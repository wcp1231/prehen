defmodule Prehen.Agent.ModelFallback do
  @moduledoc false

  @default_errors [:timeout, :rate_limit, :provider_error]

  @spec should_fallback?(map() | nil, atom()) :: boolean()
  def should_fallback?(nil, _error_type), do: false
  def should_fallback?(_candidate, :auth), do: false

  def should_fallback?(%{} = candidate, error_type) when is_atom(error_type) do
    candidate
    |> Map.get(:on_errors, Map.get(candidate, "on_errors"))
    |> normalize_on_errors()
    |> case do
      [] -> false
      allowed -> error_type in allowed
    end
  end

  def should_fallback?(_candidate, _error_type), do: false

  @spec normalize_on_errors(term()) :: [atom()]
  def normalize_on_errors(nil), do: @default_errors

  def normalize_on_errors(value) when is_list(value) do
    value
    |> Enum.map(fn
      atom when is_atom(atom) ->
        atom

      binary when is_binary(binary) ->
        binary |> String.trim() |> String.downcase() |> String.to_atom()

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def normalize_on_errors(_), do: @default_errors

  @spec next_candidate([map()], non_neg_integer(), atom()) ::
          {:ok, map(), non_neg_integer()} | :no_fallback
  def next_candidate(candidates, index, error_type)
      when is_list(candidates) and is_integer(index) and index >= 0 and is_atom(error_type) do
    next_index = index + 1

    case Enum.at(candidates, next_index) do
      %{} = candidate ->
        if should_fallback?(candidate, error_type) do
          {:ok, candidate, next_index}
        else
          :no_fallback
        end

      _ ->
        :no_fallback
    end
  end

  def next_candidate(_candidates, _index, _error_type), do: :no_fallback
end
