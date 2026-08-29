# Supervised Long-Running Process Primitive — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6b-ii**
(Foundation track). Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§4 — persistent-Capability formalism; §7 — 6b-ii's roadmap entry; §8.12 —
large-objects/persistent-capabilities grounding; §10 — what stays open).
Research log:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-research-log.md`
Part 2 (session types with runtime adaptation, Di Giusto & Pérez,
arXiv:1312.2699).

## 1. Scope

Per the parent spec's §7 entry: an OTP supervision-tree-managed process
lifecycle, typed for the revocable/restartable adaptation-safety property
from session types with runtime adaptation — the primitive both a
privileged blob store (6j) and any future persistent Capability grant
would be built from. Scoped to just the reusable primitive, not the open
question of how a general persistent Capability would be represented
(§10) — that stays open.

**Exit criterion:** a supervised OTP process can be started, can be
cleanly restarted/replaced without corrupting an in-flight session, and
refuses a restart/revoke request that arrives mid-session, per the
adaptation-safety property the grounding research requires.

**Depends on:** nothing (not even 6b-i — Riptide-native, privileged,
never goes through the WASI sandbox).

## 2. Key findings

**The parent spec's own citation of `StreamServer`'s supervision-tree
shape doesn't hold up — verified directly, not assumed.** §4 calls
`Riptide.Stream.StreamServer`'s "supervision-tree shape" "a real, citable
bridge to OTP semantics." Checked directly: `StreamServer`
(`lib/riptide/stream/stream_server.ex:1-6`) is explicitly documented as
"no GenServer of our own; Ra owns the process(es) and their durability" —
its `start_link/1` doesn't start a process at all, it polls
`Process.whereis/1` waiting for Ra's own internal, opaque supervisor to
(re)register a name. `Riptide.Stream.StreamSupervisor`
(`lib/riptide/stream/stream_supervisor.ex`) is not an OTP `Supervisor`
module — no `strategy:`, no restart types, no `DynamicSupervisor`, no
`Registry`, no `:via` tuples anywhere in `lib/` (confirmed via grep — zero
hits for all of these). This phase is genuinely new infrastructure, not a
generalization of an existing pattern.

The one real precedent for "graceful, in-flight-aware shutdown" in this
codebase is `Riptide.PlacementMembership`'s `Process.flag(:trap_exit, true)`
+ `terminate/2` graceful-drain + extended `shutdown: 10_000` timeout
(`lib/riptide/placement_membership.ex:82,118-129`;
`lib/riptide/application.ex:64-73`) — but that's a static, always-on
singleton, not a dynamically-started, per-instance addressable process.
This phase introduces `DynamicSupervisor` and `Registry` to this codebase
for the first time (both OTP-standard, no new dependency).

**A crash cannot be "refused" — the adaptation-safety property and
crash-recovery are two distinct, complementary mechanisms, not one.**
Di Giusto & Pérez's adaptation-safety property is about an in-band
request a healthy process receives and can evaluate; a crash is an
uncontrolled failure by definition, so there's no message to defer or
reject. Conflating "refuses a restart/revoke request... mid-session"
with crash-driven supervisor restarts would be a category error. Instead,
this phase builds two honestly-distinct mechanisms that share one piece
of state:

1. **Voluntary adaptation gating** — the actual paper property. An
   explicit `request_restart/1`/`request_revoke/1` call is only honored
   when the target process reports itself idle; otherwise it's rejected
   (`{:error, :session_active}`), not queued — the caller decides whether
   and when to retry.
2. **Crash-session legibility** — a complement, not the same guarantee.
   The same session-active/idle marking a process uses for its own
   `session_active?/1` check also lands in a small ETS table, so after an
   involuntary crash, `was_active_at_crash?/1` can report "this process
   was mid-session and never cleared it" — a detectable trace instead of
   silent data loss. No resumption logic; detection only.

**A real race, found while working out the exact mechanics, before any
code was written.** An initial sketch had the primitive check
`session_active?/1` from *outside* the target process (e.g.,
`:sys.get_state/1` then a separate `GenServer.stop/2` call) — a genuine
race, since a new message could start a session between the check and the
stop. Fixed by requiring the check-and-decide to happen *inside* the
target's own serialized mailbox (one small, explicit `handle_call` clause
per consumer, delegating to a shared helper) — atomic by construction,
since a GenServer processes one message at a time. This is why the
primitive is a plain module with one required boilerplate `handle_call`
clause per consumer, not something the primitive can enforce purely from
the outside.

**Restart and revoke are the same gated operation, differing only in the
supervisor follow-up.** Every managed process registers with
`DynamicSupervisor` restart type `:transient` uniformly (restarted on
abnormal exit, not on `:normal`/`:shutdown` exit). `request_restart/1`
makes the process exit abnormally — the same path a genuine crash already
takes, so voluntary restart and crash-recovery share one supervisor
mechanism for free. `request_revoke/1` makes it exit `:normal` — no
restart. No special-cased supervisor logic needed for the distinction;
`:transient`'s own semantics implement it.

## 3. Approaches considered

- **A — Adopted.** A plain module, `Riptide.SupervisedProcess`, wrapping
  a `DynamicSupervisor` + `Registry` pair. Consumers implement a 2-callback
  behaviour (`session_active?/1`, plus one boilerplate `handle_call`
  clause forwarding to a shared helper). No `use`-macro machinery — this
  codebase has no existing custom behaviour-macro convention (checked:
  zero `defmacro __using__` in `lib/` outside Phoenix's own generated
  `riptide_web.ex`), and a macro isn't needed to close the race (§2) —
  explicit code is.
- **B — Ruled out.** A `use Riptide.SupervisedProcess` macro injecting the
  control-message `handle_call` automatically (mirroring `use GenServer`
  itself). Would remove the ~4-line boilerplate per consumer, but this
  codebase has no precedent for custom `__using__` macros, and the
  boilerplate is small and explicit rather than hidden — consistent with
  this codebase's existing preference (Discovery, Matcher, DedupGate are
  all plain modules with plain functions, no macro layer anywhere in
  Sub-project 6 so far).
- **C — Ruled out.** Ra-backed (cluster-replicated) session-state
  durability instead of a local ETS table. Ruled out: 6b-ii's own exit
  criterion is about a *process* restart, not surviving a node/pod
  restart — that stronger durability guarantee is left open for whichever
  future consumer (6j, a persistent-Capability phase) actually needs it,
  per §10's own framing ("the concrete representation isn't [settled]").
  Building Ra-backed durability now would be solving a problem this
  phase's exit criterion doesn't ask for.

## 4. Module: `Riptide.SupervisedProcess`

```elixir
@callback session_active?(state :: term()) :: boolean()

@spec start(id :: term(), module(), init_arg :: term()) ::
        {:ok, pid()} | {:error, term()}
def start(id, module, init_arg)

@spec request_restart(id :: term()) ::
        :ok | {:error, :session_active} | {:error, :not_found}
def request_restart(id)

@spec request_revoke(id :: term()) ::
        :ok | {:error, :session_active} | {:error, :not_found}
def request_revoke(id)

@spec mark_session_active(id :: term()) :: :ok
def mark_session_active(id)

@spec mark_session_idle(id :: term()) :: :ok
def mark_session_idle(id)

@spec was_active_at_crash?(id :: term()) :: boolean()
def was_active_at_crash?(id)

@spec handle_stop_if_idle(module(), state :: term(), reason :: term(), GenServer.from()) ::
        {:reply, {:error, :session_active}, term()} | {:stop, term(), term()}
def handle_stop_if_idle(module, state, reason, from)
```

- `start/3` builds a `DynamicSupervisor.start_child/2` child spec with
  `restart: :transient`, `start: {module, :start_link, [id, init_arg]}`,
  and registers `{id, module}` in `Riptide.SupervisedProcess.Registry` so
  later lookups know both the process and which module's
  `session_active?/1` to call.
- `request_restart/1`/`request_revoke/1` look up `{pid, module}` via the
  Registry, then `GenServer.call(pid, {:riptide_supervised_process, :stop_if_idle, reason})`
  — `:restart_requested` (an abnormal reason, triggering `:transient`'s
  auto-restart) for restart, `:normal` for revoke. `{:error, :not_found}`
  if the Registry has no live entry.
- A consumer's own `handle_call` clause:

  ```elixir
  def handle_call({:riptide_supervised_process, :stop_if_idle, reason}, from, state) do
    Riptide.SupervisedProcess.handle_stop_if_idle(__MODULE__, state, reason, from)
  end
  ```

  `handle_stop_if_idle/4` calls `module.session_active?(state)`: if true,
  `{:reply, {:error, :session_active}, state}` (process keeps running,
  unchanged); if false, `GenServer.reply(from, :ok)` then
  `{:stop, reason, state}` — both happen inside the target's own
  serialized mailbox, closing the race from §2.
- `mark_session_active/1`/`mark_session_idle/1`/`was_active_at_crash?/1`
  read/write a small ETS table (`:public`, `:set`), owned by a tiny
  singleton `GenServer` mirroring `Riptide.Stream.Placement`'s own
  established "tiny GenServer only to own the ETS table's lifetime"
  pattern (`lib/riptide/stream/placement.ex:11-15`) — the table survives
  any individual managed process crashing, since its owner is a separate,
  always-on process under `Riptide.Application`'s top-level supervisor.

## 5. Testing

- A process starts and is directly addressable (`Registry.lookup/2`
  succeeds for its `id`).
- `request_restart/1` on an idle process (`session_active?/1` returns
  `false`) succeeds; the process exits and `:transient` brings a fresh
  instance back up under the same `id`.
- `request_restart/1` on an active process (`session_active?/1` returns
  `true`) is refused (`{:error, :session_active}`); the original process
  is confirmed still running and unchanged afterward.
- Same two cases for `request_revoke/1`, except a successful revoke does
  *not* come back (`:normal` exit, `:transient` doesn't restart on
  `:normal`).
- `request_restart/1`/`request_revoke/1` on an unregistered `id` returns
  `{:error, :not_found}`.
- Crash legibility: a process calls `mark_session_active/1`, then is
  killed uncleanly (`Process.exit(pid, :kill)`, matching
  `stream_server_test.exs`'s own convention) — `was_active_at_crash?/1`
  reports `true`. A process that calls `mark_session_idle/1` before
  exiting normally reports `false`.

## 6. Exit criterion (from parent spec §7, restated)

A supervised OTP process can be started (§5's first test), can be cleanly
restarted/replaced without corrupting an in-flight session (§5's idle
restart/revoke tests — the process either comes back cleanly via
`:transient` or is cleanly revoked, never left in an inconsistent state),
and refuses a restart/revoke request that arrives mid-session (§5's
active-session tests), per the adaptation-safety property the grounding
research requires (§2's voluntary-gating mechanism, race-free by
construction). Satisfied by §5's testing plan end-to-end.

## 7. Explicitly deferred

- The concrete persistent-Capability representation built *from* this
  primitive (§10, still open) — 6b-ii ships only the reusable primitive.
- Blob storage's own use of it (6j) — a separate phase, per the parent
  spec's connecting verdict (a privileged built-in instance of this same
  primitive, not a general WASI Capability grant).
- Cross-node/pod-restart durability of session records (Approach C, ruled
  out per §3) — left to whichever future consumer needs it; this phase's
  ETS table is single-node/in-process only.
- Queued/deferred restart requests (retry-until-safe) — callers retry
  themselves; no internal queue, keeping the primitive itself simple.
