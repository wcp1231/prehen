defmodule Prehen.Config.StructuredTest do
  use ExUnit.Case

  alias Prehen.Config.Structured
  alias Prehen.Workspace.Paths

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "prehen_structured_workspace_#{System.unique_integer([:positive])}"
      )

    global =
      Path.join(
        System.tmp_dir!(),
        "prehen_structured_global_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Paths.config_dir(workspace))
    File.mkdir_p!(Paths.global_config_dir(global))

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(global)
    end)

    %{workspace: workspace, global: global}
  end

  test "workspace config overrides global and secret_ref resolves by workspace priority", %{
    workspace: workspace,
    global: global
  } do
    write_global_config(
      global,
      "providers.yaml",
      """
      providers:
        openai_official:
          kind: official
          provider: openai
          credentials:
            api_key:
              secret_ref: providers.openai_official.api_key
          models:
            - id: gpt-5-mini
              name: GPT-5 Mini Global
              default_params:
                temperature: 0.2
                max_tokens: 2048
      """
    )

    write_workspace_config(
      workspace,
      "providers.yaml",
      """
      providers:
        openai_official:
          kind: official
          provider: openai
          credentials:
            api_key:
              secret_ref: providers.openai_official.api_key
          models:
            - id: gpt-5-mini
              name: GPT-5 Mini Workspace
              default_params:
                temperature: 0.3
                max_tokens: 1024
      """
    )

    write_global_config(
      global,
      "agents.yaml",
      """
      agents:
        coder:
          name: Coder
          description: code assistant
          system_prompt: You are coder
          capability_packs: [local_fs]
          model:
            provider_ref: openai_official
            model_id: gpt-5-mini
            params:
              temperature: 0.1
      """
    )

    write_global_config(
      global,
      "secrets.yaml",
      """
      secrets:
        providers:
          openai_official:
            api_key: sk-global
      """
    )

    write_workspace_config(
      workspace,
      "secrets.yaml",
      """
      secrets:
        providers:
          openai_official:
            api_key: sk-workspace
      """
    )

    loaded = Structured.load(workspace, global)
    assert loaded.errors == []
    refute File.exists?(Path.join(Paths.config_dir(workspace), "models.yaml"))

    assert loaded.providers["openai_official"]["models"] |> hd() |> Map.fetch!("name") ==
             "GPT-5 Mini Workspace"

    assert {:ok, resolved} = Structured.resolve_agent(loaded, "coder", max_tokens: 4096)
    [primary] = resolved.model_candidates

    assert primary.request_opts[:api_key] == "sk-workspace"
    assert primary.params.temperature == 0.1
    assert primary.params.max_tokens == 4096
  end

  test "falls back to global file when workspace config file is absent", %{
    workspace: workspace,
    global: global
  } do
    write_global_config(
      global,
      "providers.yaml",
      """
      providers:
        openai_official:
          kind: official
          provider: openai
          credentials:
            api_key:
              secret_ref: providers.openai_official.api_key
          models:
            - id: gpt-5-mini
              name: GPT-5 Mini
      """
    )

    write_global_config(
      global,
      "agents.yaml",
      """
      agents:
        coder:
          model:
            provider_ref: openai_official
            model_id: gpt-5-mini
      """
    )

    write_global_config(
      global,
      "secrets.yaml",
      """
      secrets:
        providers:
          openai_official:
            api_key: sk-global
      """
    )

    loaded = Structured.load(workspace, global)
    assert loaded.errors == []
    assert {:ok, resolved} = Structured.resolve_agent(loaded, "coder")
    [primary] = resolved.model_candidates
    assert primary.request_opts[:api_key] == "sk-global"
  end

  test "returns parse errors with file path for invalid yaml", %{
    workspace: workspace,
    global: global
  } do
    write_workspace_config(
      workspace,
      "providers.yaml",
      """
      providers:
        broken:
          kind: official
          provider openai
      """
    )

    loaded = Structured.load(workspace, global)
    assert [%{code: :config_parse_error, file: file} | _] = loaded.errors
    assert file == Path.join(Paths.config_dir(workspace), "providers.yaml")
  end

  test "validates provider schema and model name/id fields", %{
    workspace: workspace,
    global: global
  } do
    write_workspace_config(
      workspace,
      "providers.yaml",
      """
      providers:
        bad_provider:
          kind: unknown
          provider: openai
          models:
            - id: gpt-5-mini
      """
    )

    loaded = Structured.load(workspace, global)
    codes = Enum.map(loaded.errors, & &1.code)

    assert :provider_kind_invalid in codes
    assert :provider_model_missing_name in codes
  end

  test "returns secret_ref_not_found when secret is missing", %{
    workspace: workspace,
    global: global
  } do
    write_workspace_config(
      workspace,
      "providers.yaml",
      """
      providers:
        openai_official:
          kind: official
          provider: openai
          credentials:
            api_key:
              secret_ref: providers.openai_official.api_key
          models:
            - id: gpt-5-mini
              name: GPT-5 Mini
      """
    )

    write_workspace_config(
      workspace,
      "agents.yaml",
      """
      agents:
        coder:
          model:
            provider_ref: openai_official
            model_id: gpt-5-mini
      """
    )

    loaded = Structured.load(workspace, global)

    assert {:error, {:secret_ref_not_found, "providers.openai_official.api_key"}} =
             Structured.resolve_agent(loaded, "coder")
  end

  test "returns secret_value_invalid when secret type is not string", %{
    workspace: workspace,
    global: global
  } do
    write_workspace_config(
      workspace,
      "providers.yaml",
      """
      providers:
        openai_official:
          kind: official
          provider: openai
          credentials:
            api_key:
              secret_ref: providers.openai_official.api_key
          models:
            - id: gpt-5-mini
              name: GPT-5 Mini
      """
    )

    write_workspace_config(
      workspace,
      "agents.yaml",
      """
      agents:
        coder:
          model:
            provider_ref: openai_official
            model_id: gpt-5-mini
      """
    )

    write_workspace_config(
      workspace,
      "secrets.yaml",
      """
      secrets:
        providers:
          openai_official:
            api_key:
              nested: true
      """
    )

    loaded = Structured.load(workspace, global)

    assert {:error, {:secret_value_invalid, "providers.openai_official.api_key"}} =
             Structured.resolve_agent(loaded, "coder")
  end

  test "returns provider_credentials_missing when provider has no api key config", %{
    workspace: workspace,
    global: global
  } do
    write_workspace_config(
      workspace,
      "providers.yaml",
      """
      providers:
        openai_official:
          kind: official
          provider: openai
          models:
            - id: gpt-5-mini
              name: GPT-5 Mini
      """
    )

    write_workspace_config(
      workspace,
      "agents.yaml",
      """
      agents:
        coder:
          model:
            provider_ref: openai_official
            model_id: gpt-5-mini
      """
    )

    loaded = Structured.load(workspace, global)

    assert {:error, {:provider_credentials_missing, "openai_official"}} =
             Structured.resolve_agent(loaded, "coder")
  end

  test "fallback models keep on_errors and apply param merge order", %{
    workspace: workspace,
    global: global
  } do
    write_workspace_config(
      workspace,
      "providers.yaml",
      """
      providers:
        openai_official:
          kind: official
          provider: openai
          credentials:
            api_key:
              secret_ref: providers.openai_official.api_key
          models:
            - id: gpt-5-mini
              name: GPT-5 Mini
              default_params:
                temperature: 0.3
                max_tokens: 1024
        qwen_compat:
          kind: openai_compatible
          provider: openai
          endpoint: https://example.test/v1
          credentials:
            api_key:
              secret_ref: providers.qwen_compat.api_key
          models:
            - id: qwen-plus
              name: Qwen Plus
      """
    )

    write_workspace_config(
      workspace,
      "agents.yaml",
      """
      agents:
        coder:
          model:
            provider_ref: openai_official
            model_id: gpt-5-mini
            params:
              temperature: 0.1
          fallback_models:
            - provider_ref: qwen_compat
              model_id: qwen-plus
              on_errors: [timeout, rate_limit]
              params:
                max_tokens: 4096
      """
    )

    write_workspace_config(
      workspace,
      "secrets.yaml",
      """
      secrets:
        providers:
          openai_official:
            api_key: sk-openai
          qwen_compat:
            api_key: sk-qwen
      """
    )

    loaded = Structured.load(workspace, global)
    assert {:ok, resolved} = Structured.resolve_agent(loaded, "coder", temperature: 0.05)
    [primary, fallback] = resolved.model_candidates

    assert primary.params.temperature == 0.05
    assert primary.params.max_tokens == 1024
    assert fallback.params.max_tokens == 4096
    assert fallback.on_errors == [:timeout, :rate_limit]
  end

  defp write_workspace_config(workspace, filename, content) do
    path = Path.join(Paths.config_dir(workspace), filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp write_global_config(global, filename, content) do
    path = Path.join(Paths.global_config_dir(global), filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
