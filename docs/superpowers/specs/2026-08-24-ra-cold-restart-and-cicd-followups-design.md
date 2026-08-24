# Ra Cold-Restart Durability Fix & Sub-Project 2 Follow-Ups — Design

**Status:** Approved 2026-08-24.

This closes out every open item left after sub-project 2 (Docker image + CI/CD) shipped: a real,
independently-confirmed durability bug in sub-project 1's persistence layer
([issue #6](https://github.com/OpenFASTER-Standard/riptide/issues/6)), plus three minor,
unrelated cleanup items sub-project 2's own final review flagged as non-blocking but worth
closing. Bundled into one spec at the user's explicit request, even though the two halves are
otherwise independent — see §2 and §3 respectively.

## 1. Context and motivation

Sub-project 2's Task 8 end-to-end verification (pulling the real published `ghcr.io` image,
`docker rm -f`, recreating against the same volume) found that a genuine cold restart shortly
after a stream's *first* write can permanently orphan that write. This was independently
reproduced by two different parties (the implementing subagent, then the controller directly,
from a fresh local build) before being accepted as real — this exact problem space has already
produced one confirmed false alarm and one confirmed-real finding earlier in this project, so
nothing here is taken on faith.

Root cause, established via direct reading of the vendored `:ra` source
(`/work/riptide/deps/ra/src/`), not speculation:

- `Riptide.RaCluster.start_or_restart/2`'s existing logic (`:ra.restart_server/2`, falling back to
  `start_fresh_cluster/4` → `:ra.start_cluster/4`) depends on `:ra`'s own server-name registry
  (`ra_directory`, backed by `names.dets`) to decide whether a server already exists.
- `ra_directory:register_name/6` (`ra_directory.erl:68-90`) writes new registrations with a plain
  **asynchronous** `dets:insert/2` — no `dets:sync` call anywhere on that path — relying entirely
  on DETS's own `{auto_save, 500}` timer (`ra_directory.erl:54`), a hardcoded 500ms interval not
  exposed through `ra_system:config()` or any application env Riptide can tune.
- A crash inside that 500ms window loses the registration record entirely (though the write's own
  WAL entry, which goes through a completely separate fsync-before-ack path, is unaffected — this
  is *not* a regression of the "durable before ack" guarantee sub-project 1 verified; it's a
  second, independent durability gap in a different subsystem).
- On the next boot, `:ra.restart_server/2` finds nothing, and Riptide's fallback calls
  `:ra.start_cluster/4`, which **always mints a brand-new random UID** (`ra.erl:735-737`,
  `new_uid/1` — documented as random, not derivable from `cluster_name`) — silently creating an
  empty cluster instead of recovering. Confirmed via direct on-disk volume inspection: two Ra
  server directories exist afterward, one with a real `.segment` file (the orphaned write), one
  empty.
- This is not a Riptide-specific mistake: `:ra`'s own built-in `ra:start_or_restart_cluster/4,5`
  convenience helper (`ra.erl:282-322`) has the identical race, since it goes through the same
  `ra_directory`-backed existence check.

## 2. Ra registration durability fix

### 2.1 The fix: one idempotent call, no registry dependency

`ra:start_server/1,2`'s config map accepts a caller-supplied `uid` (`ra_server:ra_server_config()`
type, `ra_server.erl:189-214`; `ra.hrl:34,45-49`) — used only as a fallback-default via `new_uid/1`
when absent, never overwritten when present (`ra.erl:497-498`). Critically, starting a server with
an explicit UID recovers any existing on-disk data for that UID **without ever consulting the
DETS-backed registry**: `ra_server_sup_sup:start_server_rpc/3` (`ra_server_sup_sup.erl:55-78`)
gates only on an **ETS** lookup (`ra_directory:name_of/2`, `ra_directory.erl:140-146`) — which is
pure in-memory state, always empty after a real crash regardless of what the DETS reverse-index
says — so it proceeds straight to starting the server, which recovers from disk purely via the
UID-derived path (`ra_log:init/1` → `ra_env:server_data_dir/2`, i.e. `<data_dir>/<uid>`). As a
bonus, this call also self-heals the DETS registry for subsequent normal `restart_server` calls
(`ra_server_proc.erl:333-335`).

Riptide already computes a deterministic UID per stream (`uid_for/1`) — today only used for the
local process-name atom. The fix is to also pass it explicitly as Ra's own server UID, and always
take the same code path regardless of whether this is a genuinely new stream or a crash recovery:

```elixir
@spec start_or_restart(String.t(), :ra_machine.machine()) :: :ra.server_id()
def start_or_restart(stream_id, machine) do
  ensure_system_started()
  server_id = server_id(stream_id)
  uid = uid_for(stream_id)
  cluster_name = uid <> "_cluster"

  config = %{
    cluster_name: cluster_name,
    id: server_id,
    uid: uid,
    initial_members: [server_id],
    machine: machine
  }

  case :ra.start_server(@system, config) do
    :ok -> server_id
    {:error, {:already_started, _pid}} -> server_id
    {:error, reason} -> raise "Failed to start or restart Ra server #{inspect(server_id)}: #{inspect(reason)}"
  end
end
```

`start_fresh_cluster/4` and `server_alive?/1` are removed (no longer needed — `{:already_started,
_}` from `:ra.start_server/1,2` itself signals "already running in this VM"). Public
signature/return type (`:ra.server_id()`) is unchanged, so no caller (`StreamServer`, etc.) needs
to change. The exact required config map keys are confirmed against the pinned `:ra` version
during implementation (there may be one or two more than shown, e.g. `log_init_args`) — same
verify-against-live-source discipline used for the original `:ra` integration.

### 2.2 New regression test: genuine cold-restart simulation

The existing `ra_cluster_test.exs` crash-recovery test (`Process.exit(pid, :kill)`, same live
BEAM) cannot reproduce this bug by construction — the in-memory ETS registry Ra depends on never
goes away within one BEAM. Rather than spawning a whole second OS process/BEAM VM, reset `:ra`'s
own OTP application state directly — `Application.stop(:ra)` then restart it — which clears
exactly the in-memory state a real crash loses (ETS, registered processes) while leaving on-disk
DETS/WAL files untouched:

```elixir
test "a stream's first write survives a cold Ra-system restart" do
  stream_id = "cold-restart-" <> Uniq.UUID.uuid4()
  on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

  {:ok, _pid} = StreamServer.start_link(stream_id)
  StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

  Application.stop(:ra)
  Application.start(:ra)

  {:ok, _pid2} = StreamServer.start_link(stream_id)
  assert {:ok, [%{sequence: 1}]} = StreamServer.get_since(stream_id, 0)
end
```

This test needs `async: false` (or equivalent isolation) — `:ra` is one shared OTP application
for the whole BEAM node, so stopping it would disrupt any other test concurrently depending on a
live Ra server. Whether `Application.stop/1`+`start/1` fully resets everything relevant (vs.
leaving some supervisor/ETS state warm) is confirmed empirically during implementation.

### 2.3 Verification

- Run the new test, confirm it fails against the *old* `start_or_restart/2` (proving it actually
  detects the bug) before implementing the fix, then confirm it passes after.
- Re-run the exact `docker rm -f` + recreate repro from issue #6 against a real built image once
  the fix lands, proving it end-to-end through the container boundary, not just at the unit level.
- Re-run the full existing suite (`ra_cluster_test.exs`, `stream_server_test.exs`, and everything
  else Ra-touching) to confirm the simplified `start_or_restart/2` doesn't regress anything.

### 2.4 Out of scope

- Multi-node membership handling — this only closes the gap for a single-node (cluster size 1)
  system, consistent with everything sub-project 1 already scoped.
- Fixing `:ra`'s own library-level bug (`ra:start_or_restart_cluster/4,5` has the identical race)
  — not Riptide's to fix, and Riptide's own code no longer calls it once this ships.
- `PROGRESS.md`/issue #6 close-out is part of implementation (mark the issue fixed, update the
  sub-project 1 caveat), not a separate follow-up.

## 3. Sub-project 2 minor follow-ups

Three small, independent items sub-project 2's final whole-branch review flagged as non-blocking
("optional polish") but the user wants closed:

- **`docker-build-check` becomes a required branch-protection check.** Add
  `{"context": "docker-build-check"}` alongside the existing `{"context": "test"}` in
  `scripts/configure-branch-protection.sh`'s payload, re-run it against the real repo, verify via
  `gh api repos/OpenFASTER-Standard/riptide/branches/main/protection` that both contexts are now
  required. Closes the gap where a broken Dockerfile could merge to `main` and only surface at
  actual release-tag time.
- **`PROGRESS.md`'s PR #4 link gets a clarifying parenthetical.** PR #4's content landed on `main`
  via a squash commit after a transient GitHub API error prevented a clean "merged" state
  transition, so GitHub shows it as "Closed" rather than "Merged" — add a short note next to the
  link so a reader clicking through isn't confused by the mismatch.
- **The sub-project 2 implementation plan gets a one-line pointer.** Add a note at the top of
  `docs/superpowers/plans/2026-08-24-docker-cicd.md` that it's a frozen execution record and the
  QEMU multi-arch approach it describes was superseded during implementation — see the design
  doc's revision note for what actually shipped. The plan's historical content itself is not
  rewritten (matches how sub-project 1's plan was never retroactively edited).

## 4. Testing (overall)

See §2.3 for the durability fix's own verification. The three minor items in §3 are each verified
directly: the branch-protection change via a live `gh api` read-back, the two doc edits by reading
the rendered result.
