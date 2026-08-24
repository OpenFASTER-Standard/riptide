# Ra Cold-Restart Durability Fix & Sub-Project 2 Follow-Ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the confirmed durability bug in `Riptide.RaCluster` (issue #6 — a cold restart shortly after a stream's first write can permanently orphan it), and close out three small, unrelated cleanup items flagged during sub-project 2's final review.

**Architecture:** Replace `RaCluster.start_or_restart/2`'s branchy "try restart, else mint a random UID and start fresh" logic with a single idempotent call that always passes Riptide's already-computed deterministic UID explicitly — collapsing "genuinely new stream" and "crash recovery" into the same code path, so recovery no longer depends on `:ra`'s crash-fragile DETS-backed registry. A new regression test proves this via a genuine cold-restart simulation (stopping and restarting the `:ra` OTP application, not just killing a process in the same BEAM). Separately: make `docker-build-check` a required branch-protection check, and two small doc clarifications.

**Tech Stack:** Elixir/OTP, `:ra` (Erlang Raft library, already a dependency, pinned `~> 2.15.0`), ExUnit, GitHub CLI (`gh`), Docker.

**Spec:** `docs/superpowers/specs/2026-08-24-ra-cold-restart-and-cicd-followups-design.md`

## Global Constraints

- Elixir `~> 1.17` (currently running 1.18.4 / OTP 25). `:ra` is pinned `~> 2.15.0` in `mix.lock`
  — do not upgrade it as part of this work.
- Test command: `mix test`, run from `/work/riptide`.
- `Riptide.RaCluster` is documented as "the only module that calls into `:ra` directly" — keep
  that invariant; don't add `:ra.*` calls anywhere else.
- `Riptide.RaCluster.start_or_restart/2`'s public signature and return type (`:ra.server_id()`)
  must not change — `Riptide.Stream.StreamServer` and other callers need zero changes.
- Branch: work on a plain feature branch off `main` in the existing `/work/riptide` clone (this
  box's standing no-worktree rule — no `git worktree`). **This plan's work must go through a
  proper branch + PR, reviewed and merged only with explicit human sign-off** — the design doc
  for this plan landed directly on `main` by accident (branch protection's `enforce_admins: false`
  silently let a direct push through); that was a process slip, not the pattern to repeat.
- GitHub repo: `OpenFASTER-Standard/riptide`. Issue to close once fixed:
  [#6](https://github.com/OpenFASTER-Standard/riptide/issues/6).

---

## File Structure

Modified files:
- `lib/riptide/ra_cluster.ex` — `start_or_restart/2` rewritten; `start_fresh_cluster/4` and
  `server_alive?/1` removed (both become dead code once the branchy logic is gone — confirmed via
  repo-wide grep that neither is called anywhere outside this file).
- `test/riptide/ra_cluster_test.exs` — new regression test added (existing tests untouched; the
  existing same-BEAM-kill test still passes under the new implementation, since a same-BEAM kill
  is now just a special case of the same unified recovery path).

New files:
- `test/riptide/ra_cluster_cold_restart_test.exs` — a new, small, **`async: false`** test module
  for the cold-restart-simulation test specifically. Kept separate from `ra_cluster_test.exs`
  (which is `async: true`) because this test stops the shared `:ra` OTP application — doing that
  from an `async: true` module risks disrupting other concurrently-running test files that also
  depend on a live Ra server.
- `scripts/configure-branch-protection.sh` — modified (not new; already exists), adds
  `docker-build-check` to the required-checks payload.

Modified files (docs):
- `PROGRESS.md` — sub-project 1's issue #6 caveat resolved; PR #4 link gets a clarifying note.
- `docs/superpowers/plans/2026-08-24-docker-cicd.md` — one-line pointer added at the top.

---

### Task 1: Fix `RaCluster.start_or_restart/2` and prove it with a real cold-restart test

**Files:**
- Modify: `lib/riptide/ra_cluster.ex`
- Create: `test/riptide/ra_cluster_cold_restart_test.exs`

**Interfaces:**
- Consumes: nothing new (this is the root fix).
- Produces: `RaCluster.start_or_restart/2` — same signature `(String.t(), :ra_machine.machine()) ::
  :ra.server_id()`, same behavior for every existing caller, but no longer loses data on a cold
  restart. Task 2 depends on this being fixed and merged locally before it can verify the fix
  through a real Docker container.

- [ ] **Step 1: Write the failing regression test**

Create `test/riptide/ra_cluster_cold_restart_test.exs`:

```elixir
defmodule Riptide.RaClusterColdRestartTest do
  # :ra is a single shared OTP application for the whole BEAM node. This test
  # stops and restarts it to simulate a genuine cold restart (the in-memory
  # ETS-backed server registry a real crash loses, while on-disk WAL/DETS
  # files survive) — doing that from an `async: true` module would disrupt
  # any other test file concurrently depending on a live Ra server, so this
  # module runs alone.
  use ExUnit.Case, async: false

  alias Riptide.RaCluster
  alias Riptide.RaClusterTest.EchoMachine

  test "a stream's first write survives a cold Ra-system restart" do
    stream_id = "cold-restart-" <> Uniq.UUID.uuid4()
    on_exit(fn -> RaCluster.force_delete(stream_id) end)

    machine = {:module, EchoMachine, %{}}
    server_id = RaCluster.start_or_restart(stream_id, machine)

    assert RaCluster.process_command(server_id, {:add, "a"}) == ["a"]

    Application.stop(:ra)
    Application.start(:ra)

    restarted_id = RaCluster.start_or_restart(stream_id, machine)
    assert restarted_id == server_id
    assert RaCluster.consistent_query(restarted_id, & &1) == ["a"]
  end
end
```

This references `Riptide.RaClusterTest.EchoMachine` — the `:ra_machine` test double already
defined inside `test/riptide/ra_cluster_test.exs` (a simple list-accumulator machine, `init/1`
returns `[]`, `apply/3` handles `{:add, item}`). Since that module is nested inside
`Riptide.RaClusterTest`, reusing it from a different test file means referencing it by its full
name (`Riptide.RaClusterTest.EchoMachine`) — Elixir allows this since nested `defmodule`s are just
regular top-level modules with a dotted name, no special export needed. If this doesn't compile
for any reason, move `EchoMachine` out to `test/support/echo_machine.ex` as
`Riptide.Test.EchoMachine` instead and update both files' references — but try the direct
reference first, it's simpler.

- [ ] **Step 2: Run the test to confirm it fails against the current (buggy) implementation**

Run: `mix test test/riptide/ra_cluster_cold_restart_test.exs`
Expected: FAILS. The exact failure mode may vary (a `404`-equivalent empty result from
`consistent_query`, or `restarted_id != server_id` if a fresh cluster gets a different identity
somehow) — what matters is that it does NOT pass yet, proving this test genuinely exercises the
bug. If it unexpectedly passes already, stop and investigate before proceeding — that would mean
either the bug isn't real (contradicting the design doc's independently-confirmed finding) or this
test isn't actually triggering the cold-restart code path.

- [ ] **Step 3: Implement the fix**

Replace `lib/riptide/ra_cluster.ex`'s `start_or_restart/2` function and delete
`start_fresh_cluster/4` and `server_alive?/1` entirely (grep the file first to confirm nothing
else calls them — per the File Structure section above, nothing does). Replace with:

```elixir
  @spec start_or_restart(String.t(), :ra_machine.machine()) :: :ra.server_id()
  def start_or_restart(stream_id, machine) do
    ensure_system_started()
    server_id = server_id(stream_id)
    uid = uid_for(stream_id)

    config = %{
      id: server_id,
      uid: uid,
      cluster_name: uid <> "_cluster",
      initial_members: [server_id],
      machine: machine
    }

    case :ra.start_cluster(@system, [config]) do
      {:ok, [^server_id], []} ->
        server_id

      {:error, {:already_started, _pid}} ->
        server_id

      {:error, reason} ->
        raise "Failed to start or restart Ra server #{inspect(server_id)}: #{inspect(reason)}"
    end
  end
```

This `config` map shape (`id`, `uid`, `cluster_name`, `initial_members`, `machine`) is the exact
shape already proven to work against the pinned `:ra` version by the existing
`"Ra truncates its on-disk log once retention trimming releases a cursor"` test in
`test/riptide/ra_cluster_test.exs` (which calls `:ra.start_cluster(:default, [config])` directly
with this same key set, just with a `log_init_args` key added for a different purpose — not
needed here). Passing an explicit `uid` derived from `stream_id` (not letting `:ra` auto-generate
a random one) is what makes this idempotent: calling it again with the same `stream_id` recovers
any existing on-disk data for that `uid`, rather than depending on `:ra`'s crash-fragile
DETS-backed registry to know the server already exists.

- [ ] **Step 4: Run the regression test again**

Run: `mix test test/riptide/ra_cluster_cold_restart_test.exs`
Expected: PASSES.

**If it still fails** (i.e. `:ra.start_cluster/2` does not actually recover existing on-disk data
for an already-used `uid` — this would mean the config-map shape works for *creating* a cluster
but `start_cluster` itself still gates recovery through the same fragile registry
`start_or_restart`'s old code did), replace the implementation with this alternative using the
lower-level `:ra.start_server/2`, which more directly bypasses the registry for recovery:

```elixir
  @spec start_or_restart(String.t(), :ra_machine.machine()) :: :ra.server_id()
  def start_or_restart(stream_id, machine) do
    ensure_system_started()
    server_id = server_id(stream_id)
    uid = uid_for(stream_id)

    config = %{
      id: server_id,
      uid: uid,
      cluster_name: uid <> "_cluster",
      initial_members: [server_id],
      machine: machine
    }

    case :ra.start_server(@system, config) do
      :ok ->
        server_id

      {:error, {:already_started, _pid}} ->
        server_id

      {:error, reason} ->
        raise "Failed to start or restart Ra server #{inspect(server_id)}: #{inspect(reason)}"
    end
  end
```

Rerun Step 4 after switching. Whichever variant actually makes the test pass is the one to keep —
note in your task report which one it was and why (this determines the real, live-verified answer
the design doc's §2.1 left open, since it's exactly the kind of thing that needs confirming
against the real pinned `:ra` version rather than assumed).

- [ ] **Step 5: Run the full existing test suite**

Run: `mix test`
Expected: 0 failures, including `test/riptide/ra_cluster_test.exs`'s existing
`"data survives stopping and restarting the Ra server"` test (a same-BEAM `Process.exit(pid,
:kill)` scenario) — this should continue passing since it's now just a special case of the same
unified recovery path, not a separate code branch anymore.

- [ ] **Step 6: Check for new flakiness from the `async: false` cold-restart test**

Run `mix test` 5 times in a row (`for i in 1 2 3 4 5; do mix test || break; done`), watching
specifically for any *new* failures in other Ra-touching test files (`stream_server_test.exs`,
`stream_supervisor_test.exs`, `sse_controller_test.exs`, `replication_channel_test.exs`,
`resource_controller_test.exs`) that weren't happening before this task. If you see new flakiness
that correlates with the cold-restart test's `Application.stop(:ra)`/`start(:ra)` disrupting other
concurrently-running async tests, `async: false` alone isn't sufficient isolation in this ExUnit
configuration — investigate further (e.g., whether the new test module needs to run in true
isolation from the async pool, not just serialized among other sync tests) and document what you
find and did about it in your task report. If no new flakiness appears across 5 runs, that's
sufficient evidence `async: false` is enough here.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/ra_cluster.ex test/riptide/ra_cluster_cold_restart_test.exs
git commit -m "Fix RaCluster.start_or_restart/2: explicit deterministic uid closes cold-restart data-loss window"
```

---

### Task 2: Verify the fix through a real container, close issue #6

**Files:** none modified directly (verification only); PROGRESS.md updated as part of recording
the result.

**Interfaces:**
- Consumes: Task 1's fix, merged/present in the working tree.
- Produces: a closed GitHub issue #6 and an updated `PROGRESS.md` — nothing later in this plan
  depends on this task's own code output, but it's the proof that Task 1's fix is real beyond the
  unit-test level.

- [ ] **Step 1: Read issue #6 for the exact original repro**

Run: `gh issue view 6 --repo OpenFASTER-Standard/riptide`

Use its exact repro steps (build the image, run it with a named volume, `PUT` a triple, `docker rm
-f` immediately, run a fresh container against the same volume, `GET` the resource back) — don't
improvise a different sequence.

- [ ] **Step 2: Build the image fresh from the current working tree**

Run: `docker build --network=host -t riptide:issue6-verify .`

(`--network=host` works around a known MTU mismatch specific to this box's Docker bridge network,
documented during sub-project 2's Task 3 — not a Dockerfile issue.)

- [ ] **Step 3: Run the exact repro from issue #6 against the fixed image**

```bash
docker volume create riptide-issue6-verify
docker run -d --name riptide-issue6-verify -p 4012:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -v riptide-issue6-verify:/data \
  riptide:issue6-verify
sleep 4
curl -s -o /dev/null -w "PUT status: %{http_code}\n" -X PUT -H "Content-Type: text/turtle" \
  --data '<https://s> <https://p> <https://o> .' \
  http://localhost:4012/resources/issue6-verify
docker rm -f riptide-issue6-verify
docker run -d --name riptide-issue6-verify-2 -p 4012:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -v riptide-issue6-verify:/data \
  riptide:issue6-verify
sleep 4
curl -s -w "\nGET status: %{http_code}\n" http://localhost:4012/resources/issue6-verify
```

Expected: `GET status: 200`, with the triple present in the body. Before this fix, this
reproduced `404` on the first attempt (both when the original implementer found it and when the
controller independently re-verified it) — if it still 404s here, the fix from Task 1 is
incomplete; stop and investigate rather than proceeding to close the issue.

- [ ] **Step 4: Repeat 2 more times for confidence**

The original bug was 5/5 reproducible under tight timing; run Steps 2-3's `docker rm -f` +
recreate cycle two more times (reusing the same volume, no need to rebuild the image) to build
real confidence the fix holds, not just a single lucky pass.

- [ ] **Step 5: Clean up**

```bash
docker rm -f riptide-issue6-verify-2
docker volume rm riptide-issue6-verify
docker rmi riptide:issue6-verify
```

- [ ] **Step 6: Close issue #6 with the evidence**

```bash
gh issue close 6 --repo OpenFASTER-Standard/riptide --comment "$(cat <<'EOF'
Fixed: RaCluster.start_or_restart/2 now always passes an explicit, deterministic uid to a single
:ra.start_cluster/:ra.start_server call, so crash recovery no longer depends on :ra's
crash-fragile DETS-backed server registry. Verified two ways:

- New unit-level regression test (test/riptide/ra_cluster_cold_restart_test.exs) simulating a
  genuine cold restart via Application.stop(:ra)/start(:ra) — confirmed it fails against the old
  implementation and passes against the fix.
- The exact original repro from this issue, re-run 3 times against a fresh image build (docker rm
  -f + recreate against the same named volume) — 0/3 reproduced the data loss, vs. the original
  5/5 reproduction rate before the fix.
EOF
)"
```

- [ ] **Step 7: Update `PROGRESS.md`'s sub-project 1 caveat**

Find the paragraph starting `**Caveat added 2026-08-24, discovered during sub-project 2's Task 8
end-to-end verification**:` (currently ends with `...Tracked as
[OpenFASTER-Standard/riptide#6](https://github.com/OpenFASTER-Standard/riptide/issues/6); not yet
fixed.`). Replace just the final sentence — change `Tracked as
[OpenFASTER-Standard/riptide#6](https://github.com/OpenFASTER-Standard/riptide/issues/6); not yet
fixed.` to:

```
Fixed — see [OpenFASTER-Standard/riptide#6](https://github.com/OpenFASTER-Standard/riptide/issues/6)
for the full root-cause/verification writeup; `RaCluster.start_or_restart/2` now always uses an
explicit, deterministic Ra server UID instead of depending on `:ra`'s crash-fragile registry to
decide "restart vs. start fresh."
```

Leave the rest of that paragraph (the root-cause explanation) as-is — it's still accurate
historical context for *why* this was a bug, not a claim that it still is one.

- [ ] **Step 8: Commit**

```bash
git add PROGRESS.md
git commit -m "Update PROGRESS.md: issue #6 (Ra cold-restart data loss) fixed"
```

---

### Task 3: Make `docker-build-check` a required branch-protection check

**Files:**
- Modify: `scripts/configure-branch-protection.sh`

**Interfaces:**
- Consumes: nothing from Tasks 1-2 (fully independent).
- Produces: nothing consumed by later tasks in this plan — a standalone repo-settings change.

- [ ] **Step 1: Add the second required check**

In `scripts/configure-branch-protection.sh`, change the `required_status_checks.checks` array
from:

```json
    "checks": [{"context": "test"}]
```

to:

```json
    "checks": [{"context": "test"}, {"context": "docker-build-check"}]
```

Also update the script's explanatory comment (currently `"require the ci.yml \`test\` job, require
a PR..."`) to say `"require the ci.yml \`test\` and \`docker-build-check\` jobs, require a
PR..."`, keeping the rest of the comment as-is.

- [ ] **Step 2: Re-run it against the real repo**

Run: `./scripts/configure-branch-protection.sh`

Expected: succeeds (HTTP 200) — this is a `PUT`, safe to re-run, matches the script's own
"re-runnable" docstring.

- [ ] **Step 3: Verify the live setting**

Run: `gh api "repos/OpenFASTER-Standard/riptide/branches/main/protection" --jq '.required_status_checks.checks'`

Expected: `[{"context":"test",...},{"context":"docker-build-check",...}]` — both contexts present.

- [ ] **Step 4: Commit**

```bash
git add scripts/configure-branch-protection.sh
git commit -m "Require docker-build-check (not just test) before merging to main"
```

---

### Task 4: Two documentation clarifications

**Files:**
- Modify: `PROGRESS.md`
- Modify: `docs/superpowers/plans/2026-08-24-docker-cicd.md`

**Interfaces:**
- Consumes: nothing from earlier tasks (fully independent, bundled here since both are tiny
  documentation-only edits).

- [ ] **Step 1: Clarify the PR #4 link in `PROGRESS.md`**

Find this exact text (in sub-project 2's Status paragraph):

```
[PR #4](https://github.com/OpenFASTER-Standard/riptide/pull/4) (invalid `trivy-action` tag pin)
```

Replace with:

```
[PR #4](https://github.com/OpenFASTER-Standard/riptide/pull/4) (invalid `trivy-action` tag pin —
shows as "Closed" rather than "Merged" on GitHub because a transient API error interrupted the
merge response after the squash commit had already landed on `main`; the content is genuinely
there, only the PR's own state label is misleading)
```

- [ ] **Step 2: Add a pointer to the top of the sub-project 2 plan doc**

At the very top of `docs/superpowers/plans/2026-08-24-docker-cicd.md`, immediately after its
`# Riptide Docker Image & CI/CD Implementation Plan` title line, insert:

```markdown

> **Note:** this plan is a frozen execution record of what was originally designed — it still
> describes the QEMU-based multi-arch approach that was later found to be non-functional (BEAM's
> JIT segfaults under QEMU emulation) and replaced with native per-architecture runners during
> implementation. See `docs/superpowers/specs/2026-08-24-docker-cicd-design.md`'s revision note
> for what actually shipped. This plan's historical content below is left as-is.
```

Do not modify anything else in the plan document — its Tech Stack line, Task 5's embedded YAML,
and Task 8's text all keep describing the original (superseded) QEMU approach, which is fine; this
one pointer at the top is what tells a future reader that.

- [ ] **Step 3: Commit**

```bash
git add PROGRESS.md docs/superpowers/plans/2026-08-24-docker-cicd.md
git commit -m "Clarify PR #4 link and flag the docker-cicd plan as superseded by native-arm64"
```

---

### Task 5: Wrap up — push, open PR

**Files:** none.

**Interfaces:**
- Consumes: all of Tasks 1-4.

- [ ] **Step 1: Run the full test suite one more time**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 2: Push the branch and open a PR**

```bash
git push -u origin <branch-name>
gh pr create --repo OpenFASTER-Standard/riptide \
  --title "Fix Ra cold-restart data loss (issue #6); require docker-build-check; doc cleanup" \
  --body "$(cat <<'EOF'
## Summary
- Fixes issue #6: RaCluster.start_or_restart/2 now always uses an explicit, deterministic Ra
  server UID instead of depending on :ra's crash-fragile DETS-backed registry, closing the window
  where a cold restart shortly after a stream's first write could permanently orphan it.
- New regression test (test/riptide/ra_cluster_cold_restart_test.exs) genuinely simulates a cold
  restart via Application.stop(:ra)/start(:ra), not just a same-BEAM process kill.
- Re-verified the exact issue #6 repro against a real built image, 3/3 clean.
- docker-build-check is now a required branch-protection check alongside test.
- Two small doc clarifications (PR #4 link, docker-cicd plan superseded-QEMU pointer).

## Test plan
- [x] mix test passes in full, including the new cold-restart regression test
- [x] Confirmed the new test fails against the old implementation, passes against the fix
- [x] Re-ran the exact issue #6 Docker repro 3 times against a real built image — 0/3 reproduced
      the bug (previously 5/5)
- [x] Verified live branch-protection settings require both `test` and `docker-build-check`
EOF
)"
```

Do NOT merge this PR — leave it open for the human operator to review and merge, matching every
other merge in this project.

---

## Self-Review Notes

- **Spec coverage**: §2.1 (the fix) → Task 1 Steps 3-4. §2.2 (new test) → Task 1 Steps 1-2, 6.
  §2.3 (verification) → Task 1 Step 5, Task 2 in full. §2.4 (out of scope) — no task attempts
  multi-node handling or patching `:ra` itself. §3 (three minor items) → Tasks 3-4.
- **Placeholder scan**: no TBD/TODO. The one genuinely open technical question (does
  `:ra.start_cluster/2` or `:ra.start_server/2` correctly recover existing data for an explicit
  UID) is resolved by Task 1's own Steps 3-4 with concrete code for both outcomes and a clear
  decision rule (whichever makes the test pass) — this is a live-verification step, not a vague
  placeholder, consistent with how the original `:ra` integration was verified.
- **Type/interface consistency**: `RaCluster.start_or_restart/2`'s signature is unchanged across
  every task that references it (Task 1's two candidate implementations, Task 2's verification).
  `EchoMachine`'s reuse across `ra_cluster_test.exs` and the new `ra_cluster_cold_restart_test.exs`
  is flagged with a concrete fallback (extract to `test/support/`) if direct cross-file reference
  doesn't compile, rather than assumed to just work.
