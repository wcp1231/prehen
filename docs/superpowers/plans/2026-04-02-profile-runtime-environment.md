# Profile Runtime Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a profile-based runtime environment to Prehen so user-facing profiles come from `~/.prehen/config.yaml`, each profile runs from `~/.prehen/profiles/<profile_id>`, prompt construction is file-based and deterministic, and the first Prehen MCP tools (`skills.search` and `skills.load`) are exposed through a session-scoped local HTTP interface.

**Architecture:** Keep the current gateway session and wrapper shape, but replace ad hoc profile/runtime config with a user-facing YAML catalog plus a `ProfileEnvironment` layer. Build the system prompt from fixed fragments (`global -> SOUL.md -> AGENTS.md -> runtime context`), remove ad hoc per-session workspaces, and add a local HTTP MCP surface secured by session-bound tokens. Integrate the new prompt/environment path into `PiCodingAgent` immediately, then gate full MCP-to-`pi` wiring behind an explicit runtime-contract probe so the code stays honest about current external support.

**Tech Stack:** Elixir 1.19, OTP GenServer/Supervisor, Phoenix 1.8, Bandit, ExUnit, Jason, `yaml_elixir`, local HTTP MCP JSON-RPC, real `pi` smoke tests plus deterministic fake `pi` fixtures

---

## Scope Check

This plan covers one bounded feature set from [2026-04-02-profile-runtime-environment-design.md](/Users/wenchunpeng/Hack/elixir/prehen/docs/superpowers/specs/2026-04-02-profile-runtime-environment-design.md):

- user-facing config from `~/.prehen/config.yaml`
- fixed profile directories under `~/.prehen/profiles/<profile_id>`
- deterministic prompt construction from profile files
- session-scoped local HTTP MCP auth
- `skills.search` and `skills.load`
- wrapper integration of profile workspace and prompt
- explicit validation of whether the installed `pi` binary can consume MCP metadata

It does not cover:

- database-backed config
- multi-node routing
- rich memory APIs
- Telegram/Slack channel implementation
- browser/session/message/spawn MCP tools beyond namespace reservation

Important execution constraint:

- The Prehen-side MCP server should land regardless of `pi` compatibility.
- The final step that makes `PiCodingAgent` pass MCP metadata into `pi` is gated by a runtime-contract probe. If the installed `pi` exposes no MCP ingestion path, keep the Prehen MCP server merged but return a classified compatibility status instead of silently pretending the integration works.

## File Structure

### New files

- `lib/prehen/home.ex`
  Central source of truth for `~/.prehen`, overridable by `PREHEN_HOME` in tests.
- `lib/prehen/user_config.ex`
  Loads and validates `~/.prehen/config.yaml`.
- `lib/prehen/profile_environment.ex`
  Resolves one configured profile into fixed directories and prompt fragment file paths.
- `lib/prehen/prompt_builder.ex`
  Builds the fixed runtime system prompt string.
- `lib/prehen/mcp/session_auth.ex`
  Session-scoped MCP token registry and authorization lookup.
- `lib/prehen/mcp/tool_dispatch.ex`
  Minimal JSON-RPC method dispatch for MCP `tools/list` and `tools/call`.
- `lib/prehen/mcp/tools/skills.ex`
  Implements `skills.search` and `skills.load`.
- `lib/prehen/agents/wrappers/pi_launch_contract.ex`
  Detects whether the installed `pi` supports any MCP ingestion contract and classifies the result.
- `lib/prehen_web/controllers/mcp_controller.ex`
  Local-only MCP HTTP entrypoint.
- `test/prehen/home_test.exs`
  Covers root path resolution and `PREHEN_HOME` overrides.
- `test/prehen/user_config_test.exs`
  Covers YAML config parsing and normalization.
- `test/prehen/profile_environment_test.exs`
  Covers fixed profile directory resolution and file requirements.
- `test/prehen/prompt_builder_test.exs`
  Covers prompt composition order and missing-fragment behavior.
- `test/prehen/mcp/session_auth_test.exs`
  Covers token issuance, lookup, and invalidation.
- `test/prehen/mcp/tools/skills_test.exs`
  Covers skill indexing, visibility, search, and load behavior.
- `test/prehen/agents/wrappers/pi_launch_contract_test.exs`
  Covers MCP launch-contract detection for `pi`.
- `test/prehen/integration/mcp_skills_test.exs`
  Covers the local HTTP MCP surface for one session end to end.

### Files to modify

- `mix.exs`
  Add YAML parsing dependency.
- `config/runtime.exs`
  Keep runtime-only service settings; remove user-facing profile catalog assumptions from this file.
- `lib/prehen/config.ex`
  Switch from `Application.get_env(:prehen, :agent_profiles)` to `Prehen.UserConfig`, while keeping a narrow compatibility bridge for tests and bootstrapping.
- `lib/prehen/application.ex`
  Start MCP authorization state.
- `lib/prehen/gateway/supervisor.ex`
  Pass profile/runtime config loaded from the user config.
- `lib/prehen/agents/profile.ex`
  Reduce ambiguity: `name` remains the profile id, metadata grows to include runtime identifier and any future flags needed by the profile environment layer.
- `lib/prehen/agents/session_config.ex`
  Add `profile_dir`, `system_prompt`, and MCP metadata fields.
- `lib/prehen/agents/prompt_context.ex`
  Keep only runtime-context map creation; stop treating it as the full prompt builder.
- `lib/prehen/client/surface.ex`
  Resolve sessions from configured profile directories and reject ad hoc workspace overrides.
- `lib/prehen/gateway/session_worker.ex`
  Create and tear down session-scoped MCP auth and pass the resolved environment into the wrapper.
- `lib/prehen/gateway/session_registry.ex`
  Retain MCP token/metadata only if needed for internal lookup, not user-facing status.
- `lib/prehen/agents/registry.ex`
  Keep user-facing profile order, but source it from the new user config.
- `lib/prehen/agents/wrappers/pi_coding_agent.ex`
  Use fixed profile workspace, injected system prompt, and gated MCP metadata injection.
- `lib/prehen_web/router.ex`
  Add local MCP route.
- `lib/prehen_web/controllers/session_controller.ex`
  Stop accepting arbitrary `workspace` at session create time.
- `lib/prehen_web/controllers/inbox_controller.ex`
  Match the same profile-only session create semantics.
- `test/prehen/client/surface_test.exs`
  Cover fixed profile workspace and session create rejection of ad hoc workspace overrides.
- `test/prehen/integration/platform_runtime_test.exs`
  Cover `/sessions` without `workspace` and profile-based prompt/runtime wiring.
- `test/prehen/integration/web_inbox_test.exs`
  Cover `/inbox/sessions` without `workspace`.
- `test/prehen/agents/wrappers/pi_coding_agent_test.exs`
  Cover prompt injection, fixed workspace, and gated MCP metadata wiring.
- `test/support/fake_pi_json_agent.py`
  Add modes that assert prompt and MCP launch metadata received from the wrapper.
- `README.md`
  Document `~/.prehen/config.yaml`, profile directories, and the MCP/skills flow.
- `docs/architecture/current-system.md`
  Update the architecture snapshot to include `ProfileEnvironment`, `PromptBuilder`, and MCP.

### Files to delete or retire

- `lib/prehen/workspaces.ex`
  Delete after profile directories fully replace ad hoc session workspaces.

### Deliberate decomposition choices

- Keep `ProfileEnvironment` separate from `PromptBuilder`. Directory resolution and prompt assembly change together but do not have the same responsibility.
- Keep the MCP HTTP surface thin. Business logic lives in `Prehen.MCP.*`, not inside the controller.
- Do not force `PiCodingAgent` to pretend MCP works with `pi` if the binary exposes no compatible launch contract. Use a dedicated probe module so support status is explicit and testable.

## Task 1: Add Prehen Home Resolution and User YAML Config

**Files:**
- Create: `lib/prehen/home.ex`
- Create: `lib/prehen/user_config.ex`
- Create: `test/prehen/home_test.exs`
- Create: `test/prehen/user_config_test.exs`
- Modify: `mix.exs`
- Modify: `lib/prehen/config.ex`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Write the failing root-path and YAML config tests**

```elixir
# test/prehen/home_test.exs
defmodule Prehen.HomeTest do
  use ExUnit.Case, async: true

  alias Prehen.Home

  test "root defaults to ~/.prehen" do
    System.delete_env("PREHEN_HOME")
    assert Home.root() == Path.join(System.user_home!(), ".prehen")
    assert Home.path(["profiles", "coder"]) == Path.join([System.user_home!(), ".prehen", "profiles", "coder"])
  end

  test "root respects PREHEN_HOME override" do
    tmp = Path.join(System.tmp_dir!(), "prehen_home_test_#{System.unique_integer([:positive])}")
    System.put_env("PREHEN_HOME", tmp)
    on_exit(fn -> System.delete_env("PREHEN_HOME") end)

    assert Home.root() == tmp
    assert Home.path("config.yaml") == Path.join(tmp, "config.yaml")
  end
end
```

```elixir
# test/prehen/user_config_test.exs
defmodule Prehen.UserConfigTest do
  use ExUnit.Case, async: true

  alias Prehen.UserConfig

  test "loads profiles providers and channels from config.yaml" do
    root = Path.join(System.tmp_dir!(), "prehen_user_config_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "config.yaml"), """
    profiles:
      - id: coder
        label: Coder
        runtime: pi
        default_provider: github-copilot
        default_model: gpt-5.4-mini
        enabled: true
    providers:
      github-copilot:
        type: openai_compatible
    channels:
      web:
        enabled: true
    """)

    assert {:ok, config} = UserConfig.load(root: root)
    assert [%{id: "coder", runtime: "pi"}] = config.profiles
    assert %{"github-copilot" => %{type: "openai_compatible"}} = config.providers
    assert %{"web" => %{enabled: true}} = config.channels
  end
end
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
mix test --no-start test/prehen/home_test.exs test/prehen/user_config_test.exs
```

Expected:

```text
FAIL
```

with errors that `Prehen.Home` and `Prehen.UserConfig` do not exist and that YAML parsing is unavailable.

- [ ] **Step 3: Add YAML parsing and implement home/config loading**

Add the dependency and modules:

```elixir
# mix.exs
defp deps do
  [
    {:jason, "~> 1.4"},
    {:yaml_elixir, "~> 2.11"},
    {:phoenix, "~> 1.8"},
    {:phoenix_pubsub, "~> 2.2"},
    {:bandit, "~> 1.0"},
    {:cors_plug, "~> 3.0"}
  ]
end
```

```elixir
# lib/prehen/home.ex
defmodule Prehen.Home do
  @moduledoc false

  def root do
    System.get_env("PREHEN_HOME") ||
      Path.join(System.user_home!(), ".prehen")
  end

  def path(parts \\ [])

  def path(part) when is_binary(part), do: Path.join(root(), part)
  def path(parts) when is_list(parts), do: Path.join([root() | parts])
end
```

```elixir
# lib/prehen/user_config.ex
defmodule Prehen.UserConfig do
  @moduledoc false

  alias Prehen.Home

  def load(opts \\ []) do
    root = Keyword.get(opts, :root, Home.root())
    path = Keyword.get(opts, :path, Path.join(root, "config.yaml"))

    with {:ok, body} <- File.read(path),
         {:ok, raw} <- YamlElixir.read_from_string(body) do
      {:ok,
       %{
         profiles: normalize_profiles(Map.get(raw, "profiles", [])),
         providers: normalize_named_map(Map.get(raw, "providers", %{})),
         channels: normalize_named_map(Map.get(raw, "channels", %{}))
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_profiles(profiles) when is_list(profiles) do
    Enum.map(profiles, fn attrs ->
      %{
        id: attrs["id"],
        label: attrs["label"],
        description: attrs["description"],
        runtime: attrs["runtime"],
        default_provider: attrs["default_provider"],
        default_model: attrs["default_model"],
        enabled: Map.get(attrs, "enabled", true)
      }
    end)
  end

  defp normalize_profiles(_), do: []

  defp normalize_named_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), Map.new(value || %{})} end)
  end

  defp normalize_named_map(_), do: %{}
end
```

- [ ] **Step 4: Rewire `Prehen.Config` to prefer the user config file**

Replace the direct app-env catalog read with a user-config bridge:

```elixir
# lib/prehen/config.ex
def load(overrides \\ []) do
  user_config =
    case Keyword.get(overrides, :user_config) do
      nil -> load_user_config(overrides)
      config -> config
    end

  %{
    timeout_ms: int_config(overrides, :timeout_ms, "PREHEN_TIMEOUT_MS", @default_timeout_ms),
    trace_json: bool_config(overrides, :trace_json, "PREHEN_TRACE_JSON", false),
    agent_profiles: agent_profiles_config(overrides, user_config),
    agent_implementations: agent_implementations_config(overrides, user_config)
  }
end

defp load_user_config(overrides) do
  case UserConfig.load(root: Keyword.get(overrides, :prehen_home)) do
    {:ok, config} -> config
    {:error, _reason} -> %{profiles: [], providers: %{}, channels: %{}}
  end
end

defp agent_profiles_config(overrides, user_config) do
  overrides
  |> Keyword.get(:agent_profiles, Map.get(user_config, :profiles, []))
  |> normalize_agent_profiles()
end
```

Also update `config/runtime.exs` so profile catalog examples move out of the runtime config file.

- [ ] **Step 5: Run the focused tests and commit**

Run:

```bash
mix deps.get
mix test --no-start test/prehen/home_test.exs test/prehen/user_config_test.exs
```

Expected:

```text
PASS
```

Commit:

```bash
git add mix.exs mix.lock config/runtime.exs lib/prehen/home.ex lib/prehen/user_config.ex lib/prehen/config.ex test/prehen/home_test.exs test/prehen/user_config_test.exs
git commit -m "feat: load user config from prehen home"
```

## Task 2: Add Profile Environment, Fixed Profile Workspace, and Prompt Builder

**Files:**
- Create: `lib/prehen/profile_environment.ex`
- Create: `lib/prehen/prompt_builder.ex`
- Create: `test/prehen/profile_environment_test.exs`
- Create: `test/prehen/prompt_builder_test.exs`
- Modify: `lib/prehen/agents/session_config.ex`
- Modify: `lib/prehen/agents/prompt_context.ex`
- Modify: `lib/prehen/client/surface.ex`
- Modify: `lib/prehen/gateway/session_worker.ex`
- Modify: `lib/prehen/agents/profile.ex`
- Modify: `test/prehen/client/surface_test.exs`
- Modify: `test/prehen/integration/platform_runtime_test.exs`
- Modify: `test/prehen/integration/web_inbox_test.exs`
- Delete: `lib/prehen/workspaces.ex`

- [ ] **Step 1: Write the failing environment and prompt tests**

```elixir
# test/prehen/profile_environment_test.exs
defmodule Prehen.ProfileEnvironmentTest do
  use ExUnit.Case, async: true

  alias Prehen.ProfileEnvironment

  test "resolves a fixed profile workspace under ~/.prehen/profiles/<id>" do
    root = Path.join(System.tmp_dir!(), "prehen_env_#{System.unique_integer([:positive])}")
    profile_dir = Path.join([root, "profiles", "coder"])
    File.mkdir_p!(Path.join(profile_dir, "skills"))
    File.mkdir_p!(Path.join(profile_dir, "memory"))
    File.write!(Path.join(profile_dir, "AGENTS.md"), "Always be precise.")
    File.write!(Path.join(profile_dir, "SOUL.md"), "You are Coder.")

    profile = %{id: "coder", label: "Coder", runtime: "pi", default_provider: "github-copilot", default_model: "gpt-5.4-mini", enabled: true}

    assert {:ok, env} = ProfileEnvironment.load(profile, prehen_home: root)
    assert env.profile_dir == profile_dir
    assert env.workspace_dir == profile_dir
    assert env.global_skills_dir == Path.join(root, "skills")
    assert env.profile_skills_dir == Path.join(profile_dir, "skills")
  end
end
```

```elixir
# test/prehen/prompt_builder_test.exs
defmodule Prehen.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias Prehen.PromptBuilder

  test "builds prompt in fixed order" do
    env = %{
      soul_md: "SOUL",
      agents_md: "AGENTS",
      workspace_dir: "/tmp/prehen/profiles/coder"
    }

    session = %{
      profile_name: "coder",
      provider: "github-copilot",
      model: "gpt-5.4-mini"
    }

    prompt = PromptBuilder.build(env, session, %{skills: ["skills.search", "skills.load"]})

    assert prompt =~ "PREHEN GLOBAL"
    assert prompt =~ "SOUL"
    assert prompt =~ "AGENTS"
    assert prompt =~ "profile_name: coder"
    assert prompt =~ "skills.search"
    assert String.contains?(prompt, "PREHEN GLOBAL\n\nSOUL\n\nAGENTS")
  end
end
```

- [ ] **Step 2: Add failing session-create tests for the fixed workspace rule**

```elixir
# test/prehen/client/surface_test.exs
test "create_session rejects ad hoc workspace overrides once profile workspaces are fixed" do
  assert {:error, %{reason: :workspace_override_not_supported}} =
           Surface.create_session(agent: "coder", workspace: "/tmp/other")
end
```

```elixir
# test/prehen/integration/platform_runtime_test.exs
test "POST /sessions ignores no workspace and returns the fixed profile workspace" do
  conn = post(build_conn(), "/sessions", %{"agent" => "coder"})
  assert %{"session_id" => session_id} = json_response(conn, 201)

  conn = get(build_conn(), "/sessions/#{session_id}")
  assert %{"session" => %{"workspace" => workspace}} = json_response(conn, 200)
  assert workspace =~ "/profiles/coder"
end
```

- [ ] **Step 3: Run the focused tests to verify they fail**

Run:

```bash
mix test --no-start test/prehen/profile_environment_test.exs test/prehen/prompt_builder_test.exs test/prehen/client/surface_test.exs
```

Expected:

```text
FAIL
```

with missing-module errors and session-create behavior still using ad hoc workspaces.

- [ ] **Step 4: Implement the fixed profile environment and prompt builder**

Implement the environment and prompt modules:

```elixir
# lib/prehen/profile_environment.ex
defmodule Prehen.ProfileEnvironment do
  @moduledoc false

  alias Prehen.Home

  defstruct [
    :profile,
    :profile_dir,
    :workspace_dir,
    :agents_md,
    :soul_md,
    :memory_dir,
    :global_skills_dir,
    :profile_skills_dir
  ]

  def load(%{id: id} = profile, opts \\ []) do
    root = Keyword.get(opts, :prehen_home, Home.root())
    profile_dir = Path.join([root, "profiles", id])

    with :ok <- ensure_dir(profile_dir),
         :ok <- ensure_dir(Path.join(profile_dir, "skills")),
         :ok <- ensure_dir(Path.join(profile_dir, "memory")),
         {:ok, soul_md} <- read_optional(Path.join(profile_dir, "SOUL.md")),
         {:ok, agents_md} <- read_optional(Path.join(profile_dir, "AGENTS.md")) do
      {:ok,
       %__MODULE__{
         profile: profile,
         profile_dir: profile_dir,
         workspace_dir: profile_dir,
         soul_md: soul_md,
         agents_md: agents_md,
         memory_dir: Path.join(profile_dir, "memory"),
         global_skills_dir: Path.join(root, "skills"),
         profile_skills_dir: Path.join(profile_dir, "skills")
       }}
    end
  end

  defp ensure_dir(path), do: case File.mkdir_p(path) do :ok -> :ok; {:error, reason} -> {:error, reason} end
  defp read_optional(path), do: case File.read(path) do {:ok, body} -> {:ok, body}; {:error, :enoent} -> {:ok, ""}; other -> other end
end
```

```elixir
# lib/prehen/prompt_builder.ex
defmodule Prehen.PromptBuilder do
  @moduledoc false

  def build(env, session, capabilities) do
    [
      "PREHEN GLOBAL\nUse skills through MCP. Search first, then load.",
      normalize(env.soul_md),
      normalize(env.agents_md),
      runtime_context(session, env, capabilities)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp runtime_context(session, env, capabilities) do
    """
    profile_name: #{session.profile_name}
    provider: #{session.provider}
    model: #{session.model}
    workspace: #{env.workspace_dir}
    mcp_tools: #{Enum.join(Map.get(capabilities, :skills, []), ", ")}
    """
  end

  defp normalize(value) when is_binary(value), do: String.trim(value)
  defp normalize(_), do: ""
end
```

Update session resolution so the workspace comes from `ProfileEnvironment`, not from the incoming request:

```elixir
# lib/prehen/client/surface.ex
with false <- Keyword.has_key?(opts, :workspace),
     {:ok, profile_env} <- ProfileEnvironment.load(profile, prehen_home: Keyword.get(opts, :prehen_home)),
     {:ok, implementation} <- implementation_from_profile(profile) do
  {:ok,
   %SessionConfig{
     profile_name: profile.name,
     provider: normalize_optional_string(Keyword.get(opts, :provider)) || profile.default_provider,
     model: normalize_optional_string(Keyword.get(opts, :model)) || profile.default_model,
     prompt_profile: normalize_optional_string(Keyword.get(opts, :prompt_profile)) || profile.prompt_profile,
     workspace_policy: profile.workspace_policy,
     implementation: implementation,
     workspace: profile_env.workspace_dir,
     profile_dir: profile_env.profile_dir,
     system_prompt: PromptBuilder.build(profile_env, %{profile_name: profile.name, provider: profile.default_provider, model: profile.default_model}, %{skills: ["skills.search", "skills.load"]})
   }}
else
  true -> {:error, :workspace_override_not_supported}
end
```

- [ ] **Step 5: Run tests and commit**

Run:

```bash
mix test --no-start test/prehen/profile_environment_test.exs test/prehen/prompt_builder_test.exs test/prehen/client/surface_test.exs
PORT=4001 mix test test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs
```

Expected:

```text
PASS
```

Commit:

```bash
git add lib/prehen/profile_environment.ex lib/prehen/prompt_builder.ex lib/prehen/agents/session_config.ex lib/prehen/agents/prompt_context.ex lib/prehen/client/surface.ex lib/prehen/gateway/session_worker.ex lib/prehen/agents/profile.ex test/prehen/profile_environment_test.exs test/prehen/prompt_builder_test.exs test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs
git commit -m "feat: add profile environment and prompt builder"
```

## Task 3: Add Session-Scoped Local HTTP MCP Auth and Skills Tools

**Files:**
- Create: `lib/prehen/mcp/session_auth.ex`
- Create: `lib/prehen/mcp/tool_dispatch.ex`
- Create: `lib/prehen/mcp/tools/skills.ex`
- Create: `lib/prehen_web/controllers/mcp_controller.ex`
- Create: `test/prehen/mcp/session_auth_test.exs`
- Create: `test/prehen/mcp/tools/skills_test.exs`
- Create: `test/prehen/integration/mcp_skills_test.exs`
- Modify: `lib/prehen/application.ex`
- Modify: `lib/prehen_web/router.ex`
- Modify: `lib/prehen/gateway/session_worker.ex`

- [ ] **Step 1: Write the failing unit tests for MCP auth and skills**

```elixir
# test/prehen/mcp/session_auth_test.exs
defmodule Prehen.MCP.SessionAuthTest do
  use ExUnit.Case, async: false

  alias Prehen.MCP.SessionAuth

  test "issues and invalidates session-bound bearer tokens" do
    assert {:ok, token} = SessionAuth.issue("gw_1", "coder")
    assert {:ok, %{session_id: "gw_1", profile_id: "coder"}} = SessionAuth.lookup(token)
    assert :ok = SessionAuth.invalidate(token)
    assert {:error, :not_found} = SessionAuth.lookup(token)
  end
end
```

```elixir
# test/prehen/mcp/tools/skills_test.exs
defmodule Prehen.MCP.Tools.SkillsTest do
  use ExUnit.Case, async: true

  alias Prehen.MCP.Tools.Skills

  test "search sees global and selected profile skills only" do
    root = Path.join(System.tmp_dir!(), "prehen_mcp_skills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "skills"]))
    File.mkdir_p!(Path.join([root, "profiles", "coder", "skills"]))
    File.mkdir_p!(Path.join([root, "profiles", "reviewer", "skills"]))
    File.write!(Path.join([root, "skills", "global.md"]), "# global\nsummary: global skill")
    File.write!(Path.join([root, "profiles", "coder", "skills", "coder.md"]), "# coder\nsummary: coder skill")
    File.write!(Path.join([root, "profiles", "reviewer", "skills", "reviewer.md"]), "# reviewer\nsummary: reviewer skill")

    context = %{prehen_home: root, profile_id: "coder"}

    assert {:ok, %{skills: skills}} = Skills.search(context, %{"query" => ""})
    ids = Enum.map(skills, & &1["id"])
    assert "global:global" in ids
    assert "profile:coder:coder" in ids
    refute "profile:reviewer:reviewer" in ids
  end
end
```

- [ ] **Step 2: Write the failing MCP HTTP integration test**

```elixir
# test/prehen/integration/mcp_skills_test.exs
defmodule Prehen.Integration.MCPSkillsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Prehen.MCP.SessionAuth

  @endpoint PrehenWeb.Endpoint

  test "POST /mcp lists and calls skill tools for an authorized session" do
    assert {:ok, token} = SessionAuth.issue("gw_1", "coder")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tools/list",
        "params" => %{}
      })

    assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    assert Enum.any?(tools, &(&1["name"] == "skills.search"))
  end
end
```

- [ ] **Step 3: Run the focused tests to verify they fail**

Run:

```bash
mix test --no-start test/prehen/mcp/session_auth_test.exs test/prehen/mcp/tools/skills_test.exs
PORT=4001 mix test test/prehen/integration/mcp_skills_test.exs
```

Expected:

```text
FAIL
```

with missing-module and missing-route errors.

- [ ] **Step 4: Implement MCP auth, dispatch, tools, and HTTP entrypoint**

Add a simple supervised token registry:

```elixir
# lib/prehen/mcp/session_auth.ex
defmodule Prehen.MCP.SessionAuth do
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, Keyword.put(opts, :name, __MODULE__))
  def issue(session_id, profile_id), do: GenServer.call(__MODULE__, {:issue, session_id, profile_id})
  def lookup(token), do: GenServer.call(__MODULE__, {:lookup, token})
  def invalidate(token), do: GenServer.call(__MODULE__, {:invalidate, token})

  def init(state), do: {:ok, state}

  def handle_call({:issue, session_id, profile_id}, _from, state) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    {:reply, {:ok, token}, Map.put(state, token, %{session_id: session_id, profile_id: profile_id})}
  end

  def handle_call({:lookup, token}, _from, state) do
    reply =
      case Map.fetch(state, token) do
        {:ok, context} -> {:ok, context}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:invalidate, token}, _from, state), do: {:reply, :ok, Map.delete(state, token)}
end
```

Add the two skills tools:

```elixir
# lib/prehen/mcp/tools/skills.ex
defmodule Prehen.MCP.Tools.Skills do
  @moduledoc false

  alias Prehen.Home

  def search(context, %{"query" => query}) do
    {:ok, %{skills: indexed_skills(context) |> Enum.filter(&matches?(&1, query))}}
  end

  def search(context, _args), do: search(context, %{"query" => ""})

  def load(context, %{"id" => id}) do
    with {:ok, skill} <- fetch_visible_skill(context, id),
         {:ok, body} <- File.read(skill.path) do
      {:ok, %{"id" => id, "body" => body, "scope" => skill.scope}}
    end
  end

  defp indexed_skills(%{prehen_home: root, profile_id: profile_id}) do
    global = scan_dir(Path.join([root || Home.root(), "skills"]), "global")
    profile = scan_dir(Path.join([root || Home.root(), "profiles", profile_id, "skills"]), "profile:#{profile_id}")
    global ++ profile
  end
end
```

Add a tiny dispatcher that speaks the two MCP methods needed in phase 1:

```elixir
# lib/prehen/mcp/tool_dispatch.ex
defmodule Prehen.MCP.ToolDispatch do
  @moduledoc false

  alias Prehen.MCP.Tools.Skills

  def call(context, %{"method" => "tools/list"}) do
    {:ok,
     %{
       "tools" => [
         %{"name" => "skills.search", "description" => "Search visible skills"},
         %{"name" => "skills.load", "description" => "Load one visible skill"}
       ]
     }}
  end

  def call(context, %{"method" => "tools/call", "params" => %{"name" => "skills.search", "arguments" => args}}) do
    Skills.search(context, args)
  end

  def call(context, %{"method" => "tools/call", "params" => %{"name" => "skills.load", "arguments" => args}}) do
    Skills.load(context, args)
  end

  def call(_context, _payload), do: {:error, :method_not_found}
end
```

Add a thin JSON-RPC controller:

```elixir
# lib/prehen_web/controllers/mcp_controller.ex
defmodule PrehenWeb.MCPController do
  use Phoenix.Controller, formats: [:json]

  alias Prehen.MCP.SessionAuth
  alias Prehen.MCP.ToolDispatch

  def handle(conn, params) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, context} <- SessionAuth.lookup(token),
         {:ok, result} <- ToolDispatch.call(Map.put(context, :prehen_home, System.get_env("PREHEN_HOME")), params) do
      json(conn, %{"jsonrpc" => "2.0", "id" => params["id"], "result" => result})
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{"jsonrpc" => "2.0", "id" => params["id"], "error" => %{"code" => -32001, "message" => "unauthorized"}})
    end
  end
end
```

Wire it in:

```elixir
# lib/prehen_web/router.ex
scope "/", PrehenWeb do
  pipe_through(:api)
  post("/mcp", MCPController, :handle)
end
```

and supervise `Prehen.MCP.SessionAuth` in `Prehen.Application`.

- [ ] **Step 5: Run tests and commit**

Run:

```bash
mix test --no-start test/prehen/mcp/session_auth_test.exs test/prehen/mcp/tools/skills_test.exs
PORT=4001 mix test test/prehen/integration/mcp_skills_test.exs
```

Expected:

```text
PASS
```

Commit:

```bash
git add lib/prehen/mcp/session_auth.ex lib/prehen/mcp/tool_dispatch.ex lib/prehen/mcp/tools/skills.ex lib/prehen_web/controllers/mcp_controller.ex lib/prehen/application.ex lib/prehen_web/router.ex lib/prehen/gateway/session_worker.ex test/prehen/mcp/session_auth_test.exs test/prehen/mcp/tools/skills_test.exs test/prehen/integration/mcp_skills_test.exs
git commit -m "feat: add session-scoped mcp skills tools"
```

## Task 4: Integrate `PiCodingAgent` with Profile Prompt and Add an Honest MCP Contract Probe

**Files:**
- Create: `lib/prehen/agents/wrappers/pi_launch_contract.ex`
- Create: `test/prehen/agents/wrappers/pi_launch_contract_test.exs`
- Modify: `lib/prehen/agents/wrappers/pi_coding_agent.ex`
- Modify: `test/prehen/agents/wrappers/pi_coding_agent_test.exs`
- Modify: `test/support/fake_pi_json_agent.py`
- Create: `test/prehen/integration/pi_mcp_contract_smoke_test.exs`

- [ ] **Step 1: Write the failing contract-probe and wrapper tests**

```elixir
# test/prehen/agents/wrappers/pi_launch_contract_test.exs
defmodule Prehen.Agents.Wrappers.PiLaunchContractTest do
  use ExUnit.Case, async: true

  alias Prehen.Agents.Wrappers.PiLaunchContract

  test "returns a classified error when pi help exposes no MCP flags or env contract" do
    help = "pi --help\n--provider\n--model\n"
    assert {:error, :mcp_contract_unavailable} = PiLaunchContract.detect_from_help(help)
  end

  test "detects HTTP flag style when present" do
    help = "pi --help\n--mcp-url <url>\n--mcp-bearer-token <token>\n"
    assert {:ok, {:http_flags, %{url_flag: "--mcp-url", token_flag: "--mcp-bearer-token"}}} =
             PiLaunchContract.detect_from_help(help)
  end
end
```

```elixir
# test/prehen/agents/wrappers/pi_coding_agent_test.exs
test "build_launch_spec uses the fixed profile workspace and injected system prompt" do
  session_config =
    %SessionConfig{
      profile_name: "coder",
      provider: "github-copilot",
      model: "gpt-5.4-mini",
      prompt_profile: "coder_default",
      workspace: "/tmp/prehen/profiles/coder",
      profile_dir: "/tmp/prehen/profiles/coder",
      system_prompt: "PREHEN GLOBAL\n\nSOUL\n\nAGENTS"
    }
    |> Map.put(:implementation, fake_pi_implementation())

  assert {:ok, launch} = PiCodingAgent.build_launch_spec(session_config)
  assert launch.cwd == "/tmp/prehen/profiles/coder"
  assert launch.args |> Enum.join(" ") =~ "--append-system-prompt"
end
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
mix test --no-start test/prehen/agents/wrappers/pi_launch_contract_test.exs test/prehen/agents/wrappers/pi_coding_agent_test.exs
```

Expected:

```text
FAIL
```

with missing-module errors and no prompt/MCP contract support in the current wrapper code.

- [ ] **Step 3: Implement the `pi` MCP contract probe**

```elixir
# lib/prehen/agents/wrappers/pi_launch_contract.ex
defmodule Prehen.Agents.Wrappers.PiLaunchContract do
  @moduledoc false

  def detect(command \\ "pi") do
    case System.cmd(command, ["--help"], stderr_to_stdout: true) do
      {output, 0} -> detect_from_help(output)
      {_output, _status} -> {:error, :command_help_failed}
    end
  rescue
    _ -> {:error, :command_help_failed}
  end

  def detect_from_help(help) when is_binary(help) do
    cond do
      help =~ "--mcp-url" and help =~ "--mcp-bearer-token" ->
        {:ok, {:http_flags, %{url_flag: "--mcp-url", token_flag: "--mcp-bearer-token"}}}

      help =~ "PREHEN_MCP_URL" and help =~ "PREHEN_MCP_TOKEN" ->
        {:ok, {:http_env, %{url_env: "PREHEN_MCP_URL", token_env: "PREHEN_MCP_TOKEN"}}}

      true ->
        {:error, :mcp_contract_unavailable}
    end
  end
end
```

- [ ] **Step 4: Integrate prompt injection and gated MCP metadata into `PiCodingAgent`**

Make the launch builder use the fixed prompt and probe result:

```elixir
# lib/prehen/agents/wrappers/pi_coding_agent.ex
def build_launch_spec(%SessionConfig{} = session_config) do
  with :ok <- classify_policy(session_config),
       {:ok, provider} <- fetch_required_string(session_config, :provider, :capability_failed),
       {:ok, model} <- fetch_required_string(session_config, :model, :capability_failed),
       {:ok, workspace} <- workspace_root(session_config),
       {:ok, system_prompt} <- fetch_required_string(session_config, :system_prompt, :capability_failed),
       {:ok, command, args, env} <- implementation_command_spec(session_config) do
    prompt_args = ["--append-system-prompt", system_prompt]

    {mcp_args, mcp_env} =
      case PiLaunchContract.detect(command) do
        {:ok, {:http_flags, %{url_flag: url_flag, token_flag: token_flag}}} ->
          {[url_flag, session_config.mcp_url, token_flag, session_config.mcp_token], %{}}

        {:ok, {:http_env, %{url_env: url_env, token_env: token_env}}} ->
          {[], %{url_env => session_config.mcp_url, token_env => session_config.mcp_token}}

        {:error, :mcp_contract_unavailable} ->
          {[], %{}}
      end

    runtime_launch_args =
      normalize_pi_launch_args(args, provider, model) ++ prompt_args ++ mcp_args

    {:ok, %{executable: command, args: runtime_launch_args, cwd: workspace, env: Map.merge(env, mcp_env)}}
  end
end
```

Add an opt-in real smoke:

```elixir
# test/prehen/integration/pi_mcp_contract_smoke_test.exs
test "the installed pi exposes a recognized MCP contract" do
  assert {:ok, _contract} = PiLaunchContract.detect("pi")
end
```

- [ ] **Step 5: Run tests and commit**

Run:

```bash
mix test --no-start test/prehen/agents/wrappers/pi_launch_contract_test.exs test/prehen/agents/wrappers/pi_coding_agent_test.exs
PREHEN_REAL_PI_MCP_CONTRACT=1 mix test --no-start test/prehen/integration/pi_mcp_contract_smoke_test.exs
```

Expected:

```text
PASS
```

for the deterministic wrapper suite, and:

- either `PASS` for the real smoke once `pi` supports a recognized MCP contract
- or a classified, explicit `:mcp_contract_unavailable` result that blocks default MCP-dependent profile rollout

Commit:

```bash
git add lib/prehen/agents/wrappers/pi_launch_contract.ex lib/prehen/agents/wrappers/pi_coding_agent.ex test/prehen/agents/wrappers/pi_launch_contract_test.exs test/prehen/agents/wrappers/pi_coding_agent_test.exs test/support/fake_pi_json_agent.py test/prehen/integration/pi_mcp_contract_smoke_test.exs
git commit -m "feat: probe and wire pi mcp contract"
```

## Task 5: Update Docs and Current-System Snapshot

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture/current-system.md`

- [ ] **Step 1: Write the failing doc assertions by pinning the new terms and commands**

Update the docs so they explicitly describe:

- `~/.prehen/config.yaml`
- `~/.prehen/profiles/<profile_id>`
- fixed profile workspace semantics
- `skills.search` / `skills.load`
- local HTTP MCP

Use wording like:

```md
Prehen now treats the selected profile directory as the runtime workspace.
Users configure profiles in `~/.prehen/config.yaml`.
Skills are no longer injected wholesale into the prompt; they are discovered through Prehen MCP tools.
```

- [ ] **Step 2: Run a focused docs sanity check**

Run:

```bash
rg -n "pi-coding-agent|workspace PATH|fake_stdio|Passthrough|Stdio" README.md docs/architecture/current-system.md
```

Expected:

```text
no stale references to removed concepts
```

- [ ] **Step 3: Update README startup and config examples**

Replace `.exs`-centric examples with:

```yaml
# ~/.prehen/config.yaml
profiles:
  - id: coder
    label: Coder
    runtime: pi
    default_provider: github-copilot
    default_model: gpt-5.4-mini
    enabled: true
```

and document:

```bash
mkdir -p ~/.prehen/profiles/coder/{skills,memory}
printf "You are Coder.\n" > ~/.prehen/profiles/coder/SOUL.md
printf "Always be precise.\n" > ~/.prehen/profiles/coder/AGENTS.md
mix prehen.server
```

- [ ] **Step 4: Update the architecture snapshot**

Add the new hot-path responsibilities:

```text
Prehen.Client.Surface
  -> ProfileEnvironment
  -> PromptBuilder
  -> SessionWorker
  -> PiCodingAgent
  -> local HTTP MCP tools
  -> local pi process
```

- [ ] **Step 5: Commit**

Run:

```bash
git add README.md docs/architecture/current-system.md
git commit -m "docs: describe profile runtime environment"
```

## Self-Review

### Spec coverage

Covered:

- `~/.prehen/config.yaml` user config: Task 1
- fixed profile directories and fixed workspace semantics: Task 2
- fixed prompt composition from `SOUL.md` and `AGENTS.md`: Task 2
- `skills.search` and `skills.load`: Task 3
- session-scoped local HTTP MCP auth: Task 3
- `pi` wrapper integration of fixed prompt/workspace plus explicit MCP validation: Task 4
- docs and architecture snapshot: Task 5

Remaining intentional gate:

- Real `pi` MCP ingestion is explicitly probed in Task 4 rather than assumed. This is not a gap; it is the planned acceptance gate for an external dependency.

### Placeholder scan

- No `TODO` or `TBD` markers remain.
- Every task names exact files.
- Every task includes exact commands and expected outcomes.

### Type consistency

- `profile_id` is consistently the user-facing profile identifier.
- `workspace_dir` is consistently the fixed runtime workspace from the profile directory.
- MCP auth uses `session_id` and `profile_id` consistently through `SessionAuth`, `ToolDispatch`, and `MCPController`.
