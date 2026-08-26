# Phase 4b: Pluggable Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish *who is asking* — a pluggable `Riptide.Auth.Verifier` behaviour with a standard OIDC/JWT implementation as the default, wired into all 3 request transports (LDP HTTP, SSE, WebSocket) so a verified identity (or `nil`, anonymous) is available to a later phase (4c) to authorize against. No enforcement yet — a request with no token still proceeds; only a *present-but-invalid* token is rejected.

**Architecture:** A new `Riptide.Auth` namespace mirrors Phase 4a's `Riptide.Tenancy` pattern: a `Riptide.Auth.Verifier` behaviour (`verify(token) :: {:ok, claims} | {:error, term()}`), selected via `Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)`. The first implementation, `Riptide.Auth.Verifier.OIDC`, delegates to `Riptide.Auth.TokenConfig` (a `Joken.Config`-based module — kept separate from `Verifier.OIDC` itself because `use Joken.Config` generates its own `verify/1,2` functions that would otherwise collide with the `Riptide.Auth.Verifier` behaviour's own `verify/1` callback name). `Riptide.Auth.JwksStrategy` (`JokenJwks.DefaultStrategyTemplate`) fetches and caches signers from the configured JWKS endpoint on every node — a plain GET against a public, side-effect-free endpoint, so (unlike Phase 3d-ii's replica healer) this needs no single-leader coordination. A new `RiptideWeb.Plugs.Authenticate` plug extracts a bearer token (HTTP/SSE: `Authorization` header, SSE fallback: `?token=` query param) and assigns `conn.assigns.current_subject`. The WebSocket transport cannot see the raw `Authorization` header at all (a deliberate Phoenix security restriction — see Task 6), so it uses Phoenix's purpose-built `auth_token: true` / `Sec-WebSocket-Protocol` mechanism instead, verifying once in `Socket.connect/3` and assigning `socket.assigns.current_subject` for the connection's lifetime.

**Tech Stack:** Elixir/Phoenix, Plug, ExUnit, `joken` + `joken_jwks` (new), `Tesla.Adapter.Httpc` (OTP `:inets`/`:ssl`, no new hex dependency for the HTTP client itself).

**Spec:** `docs/superpowers/specs/2026-08-26-phase-4b-pluggable-authentication-design.md` (see its §5 for a correction, caught during this plan's own research, to the original WebSocket token-extraction approach).

## Global Constraints

- No authorization/enforcement in this phase — nothing yet checks whether `current_subject` may act on a given tenant or resource. That's Phase 4c.
- Authentication is optional at this layer: no token → `current_subject` is `nil`, request proceeds. A token that fails verification → reject (`401` for HTTP/SSE, connection refused for WebSocket).
- All 3 transports get authentication wired in — no transport is left unauthenticated while another requires a token.
- A JWKS fetch failure is a verification failure, not a silent degrade to anonymous — fails closed.
- No new runtime dependency for the JWKS HTTP client beyond what's already vendored with Erlang/OTP (`:inets`'s `Tesla.Adapter.Httpc`) — `joken_jwks` defaults to `:hackney` if unconfigured, which this plan deliberately avoids adding.
- `Riptide.Auth.JwksStrategy` only runs (application-wide, on every node, not just the 3 placement ordinals) when `Application.get_env(:riptide, :oidc_jwks_url)` is actually configured, so dev/test boot doesn't require a real OIDC provider to be reachable.

---

### Task 1: Add `joken`/`joken_jwks` dependencies + Tesla HTTP adapter wiring

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `joken` (~> 2.6), `joken_jwks` (~> 1.7), and `tesla` (~> 1.4, already present transitively via `json_ld` but pinned explicitly now since this phase depends on its public API directly) as real dependencies, resolvable and compilable. Consumed by every later task in this plan.

This is a pure setup task — there's no new behavior to TDD yet, just verifying the dependencies resolve, compile, and default to a sane HTTP adapter.

- [ ] **Step 1: Add the dependencies**

In `mix.exs`, add to `deps/0` (after the existing `{:libcluster, "~> 3.3"},` line):

```elixir
      {:joken, "~> 2.6"},
      {:joken_jwks, "~> 1.7"},
      {:tesla, "~> 1.4"},
```

- [ ] **Step 2: Add `:inets` and `:ssl` to `extra_applications`**

`joken_jwks`'s HTTP fetcher needs `Tesla.Adapter.Httpc` (built on Erlang's `:httpc`, part of `:inets`) to actually reach an HTTPS JWKS endpoint at runtime — `:inets` and `:ssl` must be started applications, not just compiled-in code. In `mix.exs`'s `application/0`:

```elixir
  def application do
    [
      mod: {Riptide.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end
```

- [ ] **Step 3: Configure Tesla's default adapter to `Httpc`, not `Hackney`**

`joken_jwks`'s own `JokenJwks.HttpFetcher` falls back to `Tesla.Adapter.Hackney` if neither `config :tesla, JokenJwks.HttpFetcher, adapter: ...` nor `config :tesla, :adapter, ...` is set (see its source: `@default_adapter Tesla.Adapter.Hackney`). Setting Tesla's own global default explicitly avoids pulling in `:hackney` as a dependency, since `Tesla.Adapter.Httpc` needs nothing beyond OTP's own `:inets`/`:ssl`. In `config/config.exs`, add (after the `config :phoenix, :json_library, Jason` line):

```elixir
# joken_jwks (Phase 4b) fetches JWKS documents over HTTPS via Tesla. Tesla's
# own built-in default adapter is already Tesla.Adapter.Httpc (OTP's
# :inets/:httpc — no extra dependency needed), but joken_jwks's own
# HttpFetcher hardcodes a *different* fallback (Tesla.Adapter.Hackney) if
# neither this key nor a per-module override is set. Setting it here
# explicitly keeps :hackney out of the dependency tree entirely.
config :tesla, adapter: Tesla.Adapter.Httpc
```

- [ ] **Step 4: Fetch and compile**

Run: `mix deps.get`
Expected: resolves `joken 2.6.2`, `joken_jwks 1.7.0`, and their own transitive dependency `jose` (`~> 1.11`) — no `:hackney` in the resolved tree.

Run: `mix compile`
Expected: clean compile, no warnings related to the new dependencies.

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures — this task changes no runtime behavior yet, only adds dependencies and config.

- [ ] **Step 6: Commit**

```bash
git add mix.exs mix.lock config/config.exs
git commit -m "Add joken/joken_jwks dependencies for Phase 4b, default Tesla to Httpc"
```

---

### Task 2: `Riptide.Auth.Verifier` behaviour + `Riptide.Auth.JwksStrategy`

**Files:**
- Create: `lib/riptide/auth/verifier.ex`
- Create: `lib/riptide/auth/jwks_strategy.ex`
- Modify: `lib/riptide/application.ex`
- Test: `test/riptide/auth/jwks_strategy_test.exs`

**Interfaces:**
- Consumes: `joken_jwks` (Task 1).
- Produces: the `Riptide.Auth.Verifier` behaviour (`@callback verify(String.t()) :: {:ok, map()} | {:error, term()}`), consumed by Task 3's `Verifier.OIDC` and Task 4's `Authenticate` plug. `Riptide.Auth.JwksStrategy`, consumed by Task 3's `TokenConfig`.

- [ ] **Step 1: Write the failing test**

Create `test/riptide/auth/jwks_strategy_test.exs`:

```elixir
defmodule Riptide.Auth.JwksStrategyTest do
  use ExUnit.Case, async: false

  alias Riptide.Auth.JwksStrategy

  setup do
    original = Application.get_env(:riptide, :oidc_jwks_url)
    on_exit(fn -> Application.put_env(:riptide, :oidc_jwks_url, original) end)
    :ok
  end

  test "init_opts/1 defaults jwks_url from Application config when not already set" do
    Application.put_env(:riptide, :oidc_jwks_url, "https://issuer.example/jwks")

    assert JwksStrategy.init_opts([])[:jwks_url] == "https://issuer.example/jwks"
  end

  test "init_opts/1 does not override an explicitly-passed jwks_url" do
    Application.put_env(:riptide, :oidc_jwks_url, "https://issuer.example/jwks")

    assert JwksStrategy.init_opts(jwks_url: "https://explicit.example/jwks")[:jwks_url] ==
             "https://explicit.example/jwks"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/auth/jwks_strategy_test.exs --trace`
Expected: FAIL — `Riptide.Auth.JwksStrategy` doesn't exist yet.

- [ ] **Step 3: Implement the behaviour and the strategy**

Create `lib/riptide/auth/verifier.ex`:

```elixir
defmodule Riptide.Auth.Verifier do
  @moduledoc """
  Behaviour for verifying a bearer token and returning its claims. Selected
  via `Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)`
  — the same config-driven swap `Riptide.Tenancy.Resolver` (Phase 4a) and
  `Riptide.RaCluster.default_ordinal_resolver/1` (Phase 3c-i) already use, so
  a different identity mechanism (API keys, WebID-OIDC) can replace this one
  later without touching the pipeline that consumes it.
  """

  @callback verify(token :: String.t()) :: {:ok, claims :: map()} | {:error, term()}
end
```

Create `lib/riptide/auth/jwks_strategy.ex`:

```elixir
defmodule Riptide.Auth.JwksStrategy do
  @moduledoc """
  `JokenJwks.DefaultStrategyTemplate` instance backing `Riptide.Auth.TokenConfig`
  — fetches and caches signers from the configured OIDC provider's JWKS
  endpoint, re-fetching on a time window whenever an unrecognized `kid` is
  seen (the template's own built-in behavior). Runs on every node that can
  serve a request (see `Riptide.Application`), not gated to the 3 placement
  ordinals the way `Riptide.Stream.ReplicaHealer` is: fetching a public JWKS
  document is a side-effect-free GET, so unlike replica repair there's no
  need for single-leader coordination — every node just fetches and caches
  independently.
  """
  use JokenJwks.DefaultStrategyTemplate

  @impl true
  def init_opts(opts) do
    Keyword.put_new(opts, :jwks_url, Application.get_env(:riptide, :oidc_jwks_url))
  end
end
```

- [ ] **Step 4: Wire `Riptide.Auth.JwksStrategy` into `Riptide.Application`**

In `lib/riptide/application.ex`, modify the `children` list to include a new conditional helper. Replace:

```elixir
    children =
      [
        {Phoenix.PubSub, name: Riptide.PubSub},
        Riptide.Stream.Placement,
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: Riptide.ClusterSupervisor]]}
      ] ++
        placement_bootstrap_children() ++
        [
          # Start a worker by calling: Riptide.Worker.start_link(arg)
          # {Riptide.Worker, arg},
          # Start to serve requests, typically the last entry
          RiptideWeb.Endpoint
        ]
```

with:

```elixir
    children =
      [
        {Phoenix.PubSub, name: Riptide.PubSub},
        Riptide.Stream.Placement,
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: Riptide.ClusterSupervisor]]}
      ] ++
        placement_bootstrap_children() ++
        auth_children() ++
        [
          # Start a worker by calling: Riptide.Worker.start_link(arg)
          # {Riptide.Worker, arg},
          # Start to serve requests, typically the last entry
          RiptideWeb.Endpoint
        ]
```

And add a new private function (after `placement_bootstrap_children/0`):

```elixir
  # Every node that can serve a request needs its own live JWKS signer
  # cache, unlike placement_bootstrap_children/0's 3-ordinal gating — see
  # Riptide.Auth.JwksStrategy's own moduledoc for why no leader coordination
  # is needed here. Conditional on real OIDC config being present at all, so
  # dev/test boot doesn't require a reachable JWKS endpoint just to start —
  # config/test.exs deliberately leaves :oidc_jwks_url unset so individual
  # tests can start their own isolated instance instead (see
  # test/riptide/auth/verifier/oidc_test.exs).
  defp auth_children do
    if Application.get_env(:riptide, :oidc_jwks_url) do
      [Riptide.Auth.JwksStrategy]
    else
      []
    end
  end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/riptide/auth/jwks_strategy_test.exs --trace`
Expected: PASS, both tests.

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures — `config/test.exs` has no `:oidc_jwks_url` set, so `auth_children/0` contributes nothing to the test suite's own application boot.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/auth/verifier.ex lib/riptide/auth/jwks_strategy.ex lib/riptide/application.ex test/riptide/auth/jwks_strategy_test.exs
git commit -m "Add Riptide.Auth.Verifier behaviour + Riptide.Auth.JwksStrategy"
```

---

### Task 3: `Riptide.Auth.TokenConfig` + `Riptide.Auth.Verifier.OIDC`

**Files:**
- Create: `lib/riptide/auth/token_config.ex`
- Create: `lib/riptide/auth/verifier/oidc.ex`
- Test: `test/riptide/auth/verifier/oidc_test.exs`

**Interfaces:**
- Consumes: `Riptide.Auth.Verifier` behaviour + `Riptide.Auth.JwksStrategy` (Task 2).
- Produces: `Riptide.Auth.Verifier.OIDC.verify/1`, the default `Riptide.Auth.Verifier` implementation. Consumed by Task 4's `Authenticate` plug and Task 6's `Socket.connect/3`, both via the config-driven `Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)` lookup — swappable by config, not just by editing that call site.

- [ ] **Step 1: Write the failing tests**

Create `test/riptide/auth/verifier/oidc_test.exs`:

```elixir
defmodule Riptide.Auth.Verifier.OIDCTest do
  use ExUnit.Case, async: false

  alias Riptide.Auth.{JwksStrategy, Verifier}

  @kid "test-signing-key"
  @issuer "https://issuer.test.example"
  @audience "riptide-test-audience"

  setup do
    original_issuer = Application.get_env(:riptide, :oidc_issuer)
    original_audience = Application.get_env(:riptide, :oidc_audience)
    Application.put_env(:riptide, :oidc_issuer, @issuer)
    Application.put_env(:riptide, :oidc_audience, @audience)

    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public_jwk_map} = JOSE.JWK.to_public_map(jwk)
    signer = Joken.Signer.create("RS256", jwk, %{"kid" => @kid})

    jwks_body = %{
      "keys" => [Map.merge(public_jwk_map, %{"kid" => @kid, "use" => "sig", "alg" => "RS256"})]
    }

    Tesla.Mock.mock_global(fn
      %{method: :get, url: "https://issuer.test.example/jwks"} ->
        Tesla.Mock.json(jwks_body)
    end)

    start_supervised!(
      {JwksStrategy,
       jwks_url: "https://issuer.test.example/jwks",
       http_adapter: Tesla.Mock,
       first_fetch_sync: true}
    )

    on_exit(fn ->
      Application.put_env(:riptide, :oidc_issuer, original_issuer)
      Application.put_env(:riptide, :oidc_audience, original_audience)
    end)

    %{signer: signer}
  end

  defp token(claims, signer) do
    default_claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "exp" => System.system_time(:second) + 3600
    }

    Joken.generate_and_sign!(%{}, Map.merge(default_claims, claims), signer)
  end

  test "verifies a correctly-signed token with valid claims", %{signer: signer} do
    assert {:ok, claims} = Verifier.OIDC.verify(token(%{"sub" => "user-1"}, signer))
    assert claims["sub"] == "user-1"
    assert claims["iss"] == @issuer
  end

  test "rejects a token signed by an unrecognized key", %{signer: _signer} do
    other_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    other_signer = Joken.Signer.create("RS256", other_jwk, %{"kid" => "unrecognized-kid"})

    assert {:error, _reason} = Verifier.OIDC.verify(token(%{"sub" => "user-1"}, other_signer))
  end

  test "rejects an expired token", %{signer: signer} do
    expired = token(%{"exp" => System.system_time(:second) - 60}, signer)
    assert {:error, _reason} = Verifier.OIDC.verify(expired)
  end

  test "rejects a token with the wrong issuer", %{signer: signer} do
    wrong_iss = token(%{"iss" => "https://not-the-configured-issuer.example"}, signer)
    assert {:error, _reason} = Verifier.OIDC.verify(wrong_iss)
  end

  test "rejects a token with the wrong audience", %{signer: signer} do
    wrong_aud = token(%{"aud" => "some-other-audience"}, signer)
    assert {:error, _reason} = Verifier.OIDC.verify(wrong_aud)
  end

  test "accepts a token whose audience is a list containing the configured audience", %{
    signer: signer
  } do
    list_aud = token(%{"aud" => ["other-audience", @audience]}, signer)
    assert {:ok, _claims} = Verifier.OIDC.verify(list_aud)
  end

  test "rejects a malformed token instead of raising" do
    assert {:error, _reason} = Verifier.OIDC.verify("not.a.jwt")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/auth/verifier/oidc_test.exs --trace`
Expected: FAIL (compile error) — `Riptide.Auth.Verifier.OIDC` and `Riptide.Auth.TokenConfig` don't exist yet.

- [ ] **Step 3: Implement `TokenConfig` and `Verifier.OIDC`**

Create `lib/riptide/auth/token_config.ex`:

```elixir
defmodule Riptide.Auth.TokenConfig do
  @moduledoc """
  `Joken.Config` token configuration backing `Riptide.Auth.Verifier.OIDC`:
  signature verification via `Riptide.Auth.JwksStrategy` (a `JokenJwks` hook),
  plus `exp` (from Joken's own generated defaults) and `iss`/`aud` claim
  checks against `Application.get_env(:riptide, :oidc_issuer/:oidc_audience)`.

  Kept as a separate module from `Riptide.Auth.Verifier.OIDC` rather than
  having the latter itself `use Joken.Config`: that macro generates its own
  `verify/1` (a default-argument shortcut for its generated `verify/2`),
  which would silently collide with — and only partially satisfy — the
  `Riptide.Auth.Verifier` behaviour's own `verify/1` callback (Joken's
  generated `verify/1` only checks the signature, not `exp`/`iss`/`aud`;
  `Riptide.Auth.Verifier.OIDC.verify/1` needs to do both). Delegating to this
  separate module's `verify_and_validate/1` avoids the name clash entirely.

  `iss`/`aud` are read from `Application` config inside the validate
  functions themselves (called at verification time, not compiled in), so
  different deployments/tests can configure a different expected
  issuer/audience without recompiling.
  """
  use Joken.Config

  add_hook(JokenJwks, strategy: Riptide.Auth.JwksStrategy)

  @impl Joken.Config
  def token_config do
    default_claims(skip: [:iss, :aud])
    |> add_claim("iss", nil, &valid_issuer?/1)
    |> add_claim("aud", nil, &valid_audience?/1)
  end

  defp valid_issuer?(iss), do: iss == Application.get_env(:riptide, :oidc_issuer)

  defp valid_audience?(aud) do
    expected = Application.get_env(:riptide, :oidc_audience)
    aud == expected or (is_list(aud) and expected in aud)
  end
end
```

Create `lib/riptide/auth/verifier/oidc.ex`:

```elixir
defmodule Riptide.Auth.Verifier.OIDC do
  @moduledoc """
  Standard OIDC/JWT `Riptide.Auth.Verifier` implementation: verifies a
  token's signature against the configured provider's JWKS endpoint and its
  `exp`/`iss`/`aud` claims, via `Riptide.Auth.TokenConfig`. This is the
  configured default (`Application.get_env(:riptide, :auth_verifier,
  Riptide.Auth.Verifier.OIDC)`) but any module implementing
  `Riptide.Auth.Verifier` can replace it.
  """
  @behaviour Riptide.Auth.Verifier

  @impl true
  def verify(token) when is_binary(token) do
    Riptide.Auth.TokenConfig.verify_and_validate(token)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide/auth/verifier/oidc_test.exs --trace`
Expected: PASS, all 7 tests.

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean. Fix anything flagged and re-run.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/auth/token_config.ex lib/riptide/auth/verifier/oidc.ex test/riptide/auth/verifier/oidc_test.exs
git commit -m "Add Riptide.Auth.TokenConfig + Riptide.Auth.Verifier.OIDC"
```

---

### Task 4: `RiptideWeb.Plugs.Authenticate`

**Files:**
- Create: `lib/riptide_web/plugs/authenticate.ex`
- Test: `test/riptide_web/plugs/authenticate_test.exs`

**Interfaces:**
- Consumes: `Riptide.Auth.Verifier` (Task 2/3), `Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)`.
- Produces: `RiptideWeb.Plugs.Authenticate`, assigning `conn.assigns.current_subject` (a claims map or `nil`) or halting with `401`. Consumed by Task 5's router wiring.

This task's own tests use a small stub verifier (config-injected, like Phase 4a's `ResolveTenant` tests used a stub-free but config-swapped real resolver) to isolate the plug's own extraction/dispatch logic from real JWT/JWKS machinery, which Task 3 already covers.

- [ ] **Step 1: Write the failing tests**

Create `test/riptide_web/plugs/authenticate_test.exs`:

```elixir
defmodule RiptideWeb.Plugs.AuthenticateTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias RiptideWeb.Plugs.Authenticate

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("valid-token"), do: {:ok, %{"sub" => "user-1"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:riptide, :auth_verifier)
    Application.put_env(:riptide, :auth_verifier, StubVerifier)
    on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original) end)
    :ok
  end

  test "assigns current_subject to nil when no token is present" do
    conn =
      :get
      |> conn("/resources/foo")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.assigns.current_subject == nil
    refute conn.halted
  end

  test "assigns current_subject from a valid Authorization: Bearer header" do
    conn =
      :get
      |> conn("/resources/foo")
      |> put_req_header("authorization", "Bearer valid-token")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.assigns.current_subject == %{"sub" => "user-1"}
    refute conn.halted
  end

  test "halts with 401 when a header token fails verification" do
    conn =
      :get
      |> conn("/resources/foo")
      |> put_req_header("authorization", "Bearer garbage")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.halted
    assert conn.status == 401
  end

  test "falls back to a ?token= query param when no header is present" do
    conn =
      :get
      |> conn("/streams/abc/subscribe?token=valid-token")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.assigns.current_subject == %{"sub" => "user-1"}
    refute conn.halted
  end

  test "prefers the header over the query param when both are present" do
    conn =
      :get
      |> conn("/streams/abc/subscribe?token=garbage")
      |> put_req_header("authorization", "Bearer valid-token")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.assigns.current_subject == %{"sub" => "user-1"}
    refute conn.halted
  end

  test "an unparseable Authorization header (no Bearer prefix) is treated as no token" do
    conn =
      :get
      |> conn("/resources/foo")
      |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.assigns.current_subject == nil
    refute conn.halted
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide_web/plugs/authenticate_test.exs --trace`
Expected: FAIL — `RiptideWeb.Plugs.Authenticate` doesn't exist yet.

- [ ] **Step 3: Implement the plug**

Create `lib/riptide_web/plugs/authenticate.ex`:

```elixir
defmodule RiptideWeb.Plugs.Authenticate do
  @moduledoc """
  Extracts a bearer token (see `extract_token/1`) and verifies it via the
  configured `Riptide.Auth.Verifier`
  (`Application.get_env(:riptide, :auth_verifier)`, defaulting to
  `Riptide.Auth.Verifier.OIDC`) — mirrors `RiptideWeb.Plugs.ResolveTenant`'s
  config-driven swap (Phase 4a).

  Unlike `ResolveTenant`, authentication is optional at this layer: no token
  present assigns `conn.assigns.current_subject` to `nil` and lets the
  request proceed as anonymous. A token *is* present but fails verification
  halts with `401` — a token that can't be checked is never silently treated
  as though it had passed. Nothing yet enforces that `current_subject` be
  non-nil for any route; that's Phase 4c's job.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case extract_token(conn) do
      nil ->
        assign(conn, :current_subject, nil)

      token ->
        verifier = Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)

        case verifier.verify(token) do
          {:ok, claims} ->
            assign(conn, :current_subject, claims)

          {:error, _reason} ->
            conn
            |> send_resp(401, "")
            |> halt()
        end
    end
  end

  # Header takes precedence over the query param when both are present, to
  # avoid ambiguity about which one is authoritative (Phase 4b design spec
  # §5). The query-param fallback exists only for SSE — browsers' native
  # `EventSource` API can't set custom request headers — but is accepted
  # here unconditionally rather than gated per-route: an LDP HTTP request
  # simply never sends a `?token=` param today, so this costs nothing there.
  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> fallback_token(conn)
    end
  end

  # `query_params` is `%Plug.Conn.Unfetched{}` until explicitly fetched —
  # the router's own `:accepts` plug never fetches it, so it must be fetched
  # here rather than read directly off `conn.query_params`.
  defp fallback_token(conn) do
    conn
    |> Plug.Conn.fetch_query_params()
    |> Map.fetch!(:query_params)
    |> Map.get("token")
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide_web/plugs/authenticate_test.exs --trace`
Expected: PASS, all 6 tests.

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide_web/plugs/authenticate.ex test/riptide_web/plugs/authenticate_test.exs
git commit -m "Add RiptideWeb.Plugs.Authenticate"
```

---

### Task 5: Wire `Authenticate` into the router + SSE controller

**Files:**
- Modify: `lib/riptide_web/router.ex`
- Test: `test/riptide_web/realtime/sse_controller_test.exs` (new, if it doesn't already exist — check first)

**Interfaces:**
- Consumes: `RiptideWeb.Plugs.Authenticate` (Task 4).
- Produces: every LDP resource route and the SSE subscribe route now run `Authenticate` (via a new `:auth` pipeline); `/health` does not. No other task depends on this one.
- No changes needed to `test/riptide_web/ldp/resource_controller_test.exs` — every one of its requests has no `Authorization` header, and optional auth means an absent token doesn't change any existing test's outcome.

- [ ] **Step 1: Check whether an SSE controller test file already exists**

Run: `ls test/riptide_web/realtime/`
If `sse_controller_test.exs` already exists, read it first and adapt Step 2 below to add to it rather than replace it wholesale.

- [ ] **Step 2: Write/extend the failing tests**

Add to (or create) `test/riptide_web/realtime/sse_controller_test.exs` — this test needs a real verifier response, so it uses the same `StubVerifier`-via-config-override pattern as Task 4, not real JWTs:

```elixir
defmodule RiptideWeb.Realtime.SseControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Riptide.Stream.StreamSupervisor

  @opts RiptideWeb.Endpoint.init([])

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("valid-token"), do: {:ok, %{"sub" => "user-1"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:riptide, :auth_verifier)
    Application.put_env(:riptide, :auth_verifier, StubVerifier)
    on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original) end)
    :ok
  end

  defp unique_stream_id, do: "sse-auth-test-#{System.unique_integer([:positive])}"

  test "subscribing with no token still succeeds (optional auth)" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.ensure_ready(stream_id)

    conn = :get |> conn("/streams/#{stream_id}/subscribe") |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
  end

  test "subscribing with a valid ?token= query param succeeds" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.ensure_ready(stream_id)

    conn =
      :get
      |> conn("/streams/#{stream_id}/subscribe?token=valid-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
  end

  test "subscribing with an invalid token is rejected with 401 before touching the stream" do
    stream_id = unique_stream_id()

    conn =
      :get
      |> conn("/streams/#{stream_id}/subscribe?token=garbage")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 401
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/riptide_web/realtime/sse_controller_test.exs --trace`
Expected: FAIL — the SSE route isn't behind `Authenticate` yet, so the invalid-token test gets a 200/503 instead of 401 (and the valid-token/no-token tests may already incidentally pass, since `Authenticate` isn't wired in yet at all).

- [ ] **Step 4: Update the router**

Replace the full contents of `lib/riptide_web/router.ex`:

```elixir
defmodule RiptideWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json", "turtle", "ld+json"]
  end

  pipeline :tenant do
    plug RiptideWeb.Plugs.ResolveTenant
  end

  pipeline :auth do
    plug RiptideWeb.Plugs.Authenticate
  end

  scope "/" do
    pipe_through :api

    get "/health", RiptideWeb.HealthController, :show
  end

  scope "/" do
    pipe_through [:api, :auth]

    get "/streams/:stream_id/subscribe", RiptideWeb.Realtime.SseController, :subscribe
  end

  scope "/tenants/:tenant_id" do
    pipe_through [:api, :tenant, :auth]

    get "/resources/*path", RiptideWeb.LDP.ResourceController, :show
    post "/resources/*path", RiptideWeb.LDP.ResourceController, :create_child
    put "/resources/*path", RiptideWeb.LDP.ResourceController, :replace
    delete "/resources/*path", RiptideWeb.LDP.ResourceController, :delete
    patch "/resources/*path", RiptideWeb.LDP.ResourceController, :patch
  end
end
```

`/health` is deliberately left out of the `:auth` pipeline — it's a liveness probe, not one of the 3 request transports this phase's scope covers.

- [ ] **Step 5: Run the SSE tests to verify they pass**

Run: `mix test test/riptide_web/realtime/sse_controller_test.exs --trace`
Expected: PASS, all 3 tests.

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures — every existing `resource_controller_test.exs` request has no `Authorization` header, so `current_subject` will be `nil` for all of them (optional auth means this doesn't change their outcomes at all).

- [ ] **Step 7: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 8: Commit**

```bash
git add lib/riptide_web/router.ex test/riptide_web/realtime/sse_controller_test.exs
git commit -m "Wire RiptideWeb.Plugs.Authenticate into the router"
```

---

### Task 6: WebSocket authentication via `connect/3`

**Files:**
- Modify: `lib/riptide_web/endpoint.ex`
- Modify: `lib/riptide_web/realtime/socket.ex`
- Modify: `test/riptide_web/realtime/replication_channel_test.exs`

**Interfaces:**
- Consumes: `Riptide.Auth.Verifier` (Task 2/3), Phoenix's `auth_token: true` socket option.
- Produces: `RiptideWeb.Realtime.Socket.connect/3` verifies a token (if present) and assigns `socket.assigns.current_subject`. No other task depends on this one.

**Important correction, carried over from the design spec** (see spec §5): Phoenix's `Phoenix.Socket.connect/3` cannot see a raw `Authorization` header — Phoenix deliberately withholds arbitrary request headers here (cross-origin WebSocket handshake safety). The mechanism is instead `socket/3`'s `auth_token: true` option, which reads a token the client sends via the `Sec-WebSocket-Protocol` header (prefixed `"base64url.bearer.phx."`, standard-base64 encoded) and surfaces it as `connect_info.auth_token`.

- [ ] **Step 1: Write the failing tests**

Add to `test/riptide_web/realtime/replication_channel_test.exs` — add a `StubVerifier` module and a `setup` block near the top of the module (after the `@endpoint RiptideWeb.Endpoint` line), and 3 new tests at the end (before the closing `end`):

```elixir
  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("valid-token"), do: {:ok, %{"sub" => "user-1"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:riptide, :auth_verifier)
    Application.put_env(:riptide, :auth_verifier, StubVerifier)
    on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original) end)
    :ok
  end
```

```elixir
  test "connecting with no auth_token still succeeds, current_subject is nil" do
    assert {:ok, socket} = connect(Socket, %{})
    assert socket.assigns.current_subject == nil
  end

  test "connecting with a valid auth_token assigns current_subject" do
    assert {:ok, socket} = connect(Socket, %{}, connect_info: %{auth_token: "valid-token"})
    assert socket.assigns.current_subject == %{"sub" => "user-1"}
  end

  test "connecting with an invalid auth_token is refused" do
    assert {:error, _reason} = connect(Socket, %{}, connect_info: %{auth_token: "garbage"})
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide_web/realtime/replication_channel_test.exs --trace`
Expected: FAIL on the 2 new token-related tests — `Socket.connect/3` currently ignores `connect_info` entirely and always returns `{:ok, socket}` with no `current_subject` assign. (The no-token test may or may not already pass depending on whether `socket.assigns.current_subject` raises a `KeyError` vs. just not matching `nil` — either way it's a failure until Step 3/4 land.)

- [ ] **Step 3: Enable `auth_token` on the endpoint's socket declaration**

In `lib/riptide_web/endpoint.ex`, change:

```elixir
  socket "/replication", RiptideWeb.Realtime.Socket, websocket: true
```

to:

```elixir
  socket "/replication", RiptideWeb.Realtime.Socket, websocket: true, auth_token: true
```

`auth_token: true` alone is sufficient — `Phoenix.Socket.Transport.load_config/1` automatically prepends `:auth_token` to the effective `connect_info` list once this option is set; no explicit `connect_info: [...]` needs adding.

- [ ] **Step 4: Implement `Socket.connect/3`**

Replace the full contents of `lib/riptide_web/realtime/socket.ex`:

```elixir
defmodule RiptideWeb.Realtime.Socket do
  @moduledoc """
  Phoenix Socket for StreamLD's WebSocket replication transport — mounts
  `ReplicationChannel` on the `replication:*` topic.

  Authentication is optional (Phase 4b): a connection with no `auth_token`
  proceeds with `socket.assigns.current_subject` set to `nil`; a connection
  presenting a token that fails verification is refused outright. The token
  itself arrives via Phoenix's `auth_token: true` socket option (see
  `RiptideWeb.Endpoint`), which reads it from the `Sec-WebSocket-Protocol`
  header rather than a raw `Authorization` header — Phoenix does not expose
  arbitrary request headers to `connect/3` at all, for cross-origin
  handshake safety. Verification happens once, here, at connect time; a
  channel `join/3` never re-verifies — the socket-level identity already
  applies to every channel joined on it. Assigns no socket id, since there's
  no per-connection session distinguishing one reader from another.
  """
  use Phoenix.Socket

  channel "replication:*", RiptideWeb.Realtime.ReplicationChannel

  @impl true
  def connect(_params, socket, connect_info) do
    case Map.get(connect_info, :auth_token) do
      nil ->
        {:ok, assign(socket, :current_subject, nil)}

      token ->
        verifier = Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)

        case verifier.verify(token) do
          {:ok, claims} -> {:ok, assign(socket, :current_subject, claims)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def id(_socket), do: nil
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/riptide_web/realtime/replication_channel_test.exs --trace`
Expected: PASS, all 8 tests (5 pre-existing + 3 new).

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 7: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 8: Commit**

```bash
git add lib/riptide_web/endpoint.ex lib/riptide_web/realtime/socket.ex test/riptide_web/realtime/replication_channel_test.exs
git commit -m "Add WebSocket authentication via Phoenix's auth_token mechanism"
```

---

### Task 7: Runtime config wiring + live proof against a real OIDC provider

**Files:**
- Modify: `config/runtime.exs`
- Modify: `PROGRESS.md`

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: real `RIPTIDE_OIDC_ISSUER`/`RIPTIDE_OIDC_AUDIENCE`/`RIPTIDE_OIDC_JWKS_URL` env-var wiring for non-test environments, plus documented proof the whole chain works against a real (if disposable) OIDC-compliant issuer. Terminal task.

- [ ] **Step 1: Wire runtime OIDC config**

In `config/runtime.exs`, add (after the existing `libcluster`/`POD_IP` block, before the `if config_env() == :prod do` block):

```elixir
# OIDC config is optional outside :test — Riptide.Application's
# auth_children/0 only starts Riptide.Auth.JwksStrategy when
# :oidc_jwks_url is actually set, so a deployment that hasn't configured an
# identity provider yet still boots (every request's current_subject is
# simply always nil — no enforcement exists until Phase 4c). :test is
# excluded entirely: config/test.exs deliberately leaves this unset so the
# test suite's own app boot never tries to reach a real JWKS endpoint.
if config_env() != :test do
  oidc_issuer = System.get_env("RIPTIDE_OIDC_ISSUER")
  oidc_audience = System.get_env("RIPTIDE_OIDC_AUDIENCE")
  oidc_jwks_url = System.get_env("RIPTIDE_OIDC_JWKS_URL")

  if oidc_issuer && oidc_audience && oidc_jwks_url do
    config :riptide,
      oidc_issuer: oidc_issuer,
      oidc_audience: oidc_audience,
      oidc_jwks_url: oidc_jwks_url
  end
end
```

- [ ] **Step 2: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures — `config/runtime.exs` isn't evaluated by `mix test` at all in a normal dev checkout (it only runs for releases/`mix phx.server` with `RELEASE_MODE`), so this step is a sanity check that nothing else broke, not a direct exercise of this change.

- [ ] **Step 3: Live proof against a real, disposable OIDC provider**

This step is a manual/scripted verification pass, not new permanent test-suite code — matching this project's established "disposable, no lasting infrastructure" precedent (e.g. Phase 3d-i's live GKE spike).

Using the `node`/`npx` already available in this environment, start a real, spec-compliant, throwaway OIDC provider via the `oidc-provider` npm package (no Docker required):

```bash
mkdir -p /tmp/phase-4b-oidc-proof && cd /tmp/phase-4b-oidc-proof
npm init -y >/dev/null 2>&1
npm install oidc-provider >/dev/null 2>&1
```

Write a minimal disposable provider script (`provider.js`) configured with a single static `client_credentials`-grant client and the default dev-mode JWKS (auto-generated on boot), listening on `http://127.0.0.1:3999`, with `issuer: "http://127.0.0.1:3999"`. Start it with `node provider.js &`, confirm `curl http://127.0.0.1:3999/.well-known/openid-configuration` returns real discovery metadata including a `jwks_uri`.

Start Riptide itself (`mix phx.server`, or reuse the always-on `/work/app`-style dev pattern if one exists for this repo) with:

```bash
RIPTIDE_OIDC_ISSUER=http://127.0.0.1:3999 \
RIPTIDE_OIDC_AUDIENCE=riptide-proof \
RIPTIDE_OIDC_JWKS_URL=http://127.0.0.1:3999/jwks \
PHX_SERVER=true mix phx.server
```

Obtain a real token via the client_credentials grant:

```bash
curl -s -X POST http://127.0.0.1:3999/token \
  -u '<client_id>:<client_secret>' \
  -d 'grant_type=client_credentials&audience=riptide-proof' | jq -r .access_token
```

Prove the chain end-to-end with 2 requests against a real tenant-scoped resource route:

- A request with a garbage `Authorization: Bearer` value gets `401`.
- The same request with the real token obtained above does **not** get `401` (it gets whatever the resource's actual status is, e.g. `404` for a never-written resource) — proving the token was actually verified against the real provider's real JWKS, not just accepted unconditionally.

Record the concrete evidence (the two `curl` outputs/status codes) in this task's completion notes before tearing everything down: `kill` the `node provider.js` process, stop `mix phx.server`, `rm -rf /tmp/phase-4b-oidc-proof`.

- [ ] **Step 4: Update the `## 4. Security & multi-tenancy` section of `PROGRESS.md`**

In `PROGRESS.md`, find the `**Phasing:**` list under `## 4. Security & multi-tenancy — decomposed into phases` and replace the `Phase 4b` line:

```markdown
- **Phase 4b — Pluggable authentication.** Not yet designed.
```

with:

```markdown
- **Phase 4b — Pluggable authentication.** **Shipped 2026-08-26** — see
  `docs/superpowers/specs/2026-08-26-phase-4b-pluggable-authentication-design.md`. A pluggable
  `Riptide.Auth.Verifier` behaviour (config-selected, defaulting to `Riptide.Auth.Verifier.OIDC` —
  standard OIDC/JWT via `joken`+`joken_jwks`) feeds a new `RiptideWeb.Plugs.Authenticate` plug,
  applied to all 3 request transports (LDP HTTP, SSE, WebSocket). Authentication is optional at
  this layer — no token proceeds as anonymous (`current_subject: nil`); a present-but-invalid
  token is rejected (`401` for HTTP/SSE, connection refused for WebSocket). WebSocket auth uses
  Phoenix's purpose-built `auth_token`/`Sec-WebSocket-Protocol` mechanism rather than a header,
  since Phoenix deliberately doesn't expose the raw `Authorization` header to `Socket.connect/3`.
  Live-proved end-to-end against a real, disposable `oidc-provider`-based OIDC issuer. No
  authorization/enforcement yet — that's Phase 4c.
```

And update the trailing `**Status**:` line:

```markdown
**Status**: Phases 4a-4b shipped 2026-08-26. Phases 4c-4d not yet designed.
```

- [ ] **Step 5: Commit**

```bash
git add config/runtime.exs PROGRESS.md
git commit -m "Wire runtime OIDC config, live-prove Phase 4b, mark it shipped in PROGRESS.md"
```
