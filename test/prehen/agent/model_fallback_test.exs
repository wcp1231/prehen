defmodule Prehen.Agent.ModelFallbackTest do
  use ExUnit.Case

  alias Prehen.Agent.ModelFallback

  test "uses next fallback candidate when error type is allowed" do
    candidates = [
      %{model: "openai:gpt-5-mini", on_errors: []},
      %{model: "openai:gpt-5", on_errors: [:timeout, :rate_limit]}
    ]

    assert {:ok, next, 1} = ModelFallback.next_candidate(candidates, 0, :timeout)
    assert next.model == "openai:gpt-5"
  end

  test "auth errors never auto-fallback" do
    candidate = %{model: "openai:gpt-5", on_errors: [:auth, :timeout]}
    refute ModelFallback.should_fallback?(candidate, :auth)
  end

  test "normalize_on_errors returns defaults when nil" do
    assert ModelFallback.normalize_on_errors(nil) == [:timeout, :rate_limit, :provider_error]
  end

  test "next_candidate returns no_fallback when there is no next candidate" do
    candidates = [%{model: "openai:gpt-5-mini", on_errors: []}]
    assert :no_fallback == ModelFallback.next_candidate(candidates, 0, :timeout)
  end
end
