# Layer 0/Layer 2 Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a real, running, provisional boundary that lets a sandboxed WASM module react to riptide's materialized state and write back through the existing, already-hardened commit path — task-master task 5's five subtasks, as one coherent unit.

**Architecture:** A new `riptide_module` library hosts core-WASM guest modules (via the `wasmtime` OCaml bindings) behind a hand-rolled ABI, each call sequence checked against a declared per-module state machine, each instance isolated one-per-invocation. A reactor dispatch loop invokes a module when a `merge_key` it subscribes to gets a new materialized value; a module's writes flow back through the *existing* `Batch_commit.propose`, now wrapped with a mandatory, universal authorization checkpoint. Module artifacts are verified (signature + provenance) by shelling out to the real `cosign` binary before they ever load.

**Tech Stack:** OCaml 5, `wasmtime` (OCaml bindings, core WASM only — no Component Model), `cosign` (external binary, shelled out to), Eio, Alcotest.

**Spec:** `docs/superpowers/specs/2026-09-30-layer0-layer2-boundary-design.md`

## Global Constraints

- No rule ships without real, running, tested code in the same change (`CLAUDE.md`'s "no spec without running code").
- Modules execute outside consensus; writes flow through the existing `Batch_commit.propose`, never a new replicated-execution path (spec Decision 1).
- Modules are triggered by materialized state changes per `merge_key`, never raw commits (spec Decision 2).
- The ABI is core WASM plus a hand-rolled calling convention via the `wasmtime` OCaml bindings — true Component Model/WIT is explicitly out of scope (spec Decision 3).
- Session-type checking is a hand-rolled per-module finite-state machine, not `nuscr` (spec Decision 4).
- SFI isolation (one fresh WASM instance per invocation, never reused, never shared across modules) ships now; the microVM tier is a real type with a clear "not yet implemented" behavior, not a built Firecracker integration (spec Decision 5).
- The admission gate shells out to the real `cosign` binary; no hand-rolled cryptographic or attestation-verification logic (spec Decision 6).
- The authorization checkpoint is universal — inside `Batch_commit`'s shared `propose` path, applying to every write, module-originated or not (spec Decision 7).
- A denial is observable via a counter shaped like `Batch_commit.materialize_write_failures` (a monotonic, process-lifetime count) — no new ad hoc refusal convention invented from scratch.
- `Batch_commit.create`'s `authorize` argument is *required*, not optional — mirroring this module's own established "an explicit parameter forces a visible choice" philosophy (`encryption_sink`'s doc comment) and `replica`'s own required-ness.

## Review Focus

- A module whose `handle` entrypoint returns without ever calling `propose_write` — the reactor must treat "chose not to act" as a legitimate no-op, not an error.
- Two different modules subscribed to the same `merge_key`, one denied by `authorize` and one allowed — one module's denial must never affect its sibling's own independent dispatch or outcome.
- A module whose declared protocol (Task 1's FSM) is itself malformed — referencing an unknown state, or declaring two transitions for the same `(state, call)` pair — must be rejected at load time with a clear error, never silently accepted or crashing the loader.
- Two concurrent invocations of the *same* module (two `merge_key` changes arriving close together) must not share any mutable state across their two fresh WASM instances — including the protocol checker, which must be a fresh value per invocation, not shared per-module.
- `cosign` missing from `PATH`, or exiting nonzero for a reason other than verification failure (e.g. a malformed command) — the gate must fail closed (refuse the artifact) exactly like a real verification failure, never silently skip the check.

---

### Task 1: Session-type protocol FSM

**Files:**
- Create: `lib/module/dune`
- Create: `lib/module/protocol.ml`
- Create: `lib/module/protocol.mli`
- Test: `test/test_module_protocol.ml`

**Interfaces:**
- Produces: `Riptide_module.Protocol.t` (a validated protocol), `Riptide_module.Protocol.checker` (one in-progress run), `create`, `start`, `step`, `current_state` — consumed by Task 4 (loader enforcement).

- [ ] **Step 1: Write the failing tests**

```ocaml
let test_create_rejects_a_transition_naming_an_unknown_state () =
  Alcotest.check_raises "unknown to_state is rejected"
    (Invalid_argument "Protocol.create: transition to unknown state \"missing\"") (fun () ->
      ignore
        (Protocol.create ~states:[ "init" ] ~initial:"init"
           ~transitions:[ { from_state = "init"; on_call = "handle"; to_state = "missing" } ]))

let test_create_rejects_a_nondeterministic_protocol () =
  Alcotest.check_raises "two transitions for the same (state, call) pair is rejected"
    (Invalid_argument
       "Protocol.create: state \"init\" already has a transition on call \"handle\"") (fun () ->
      ignore
        (Protocol.create ~states:[ "init"; "a"; "b" ] ~initial:"init"
           ~transitions:
             [
               { from_state = "init"; on_call = "handle"; to_state = "a" };
               { from_state = "init"; on_call = "handle"; to_state = "b" };
             ]))

let test_step_follows_a_valid_transition () =
  let p =
    Protocol.create ~states:[ "init"; "ready" ] ~initial:"init"
      ~transitions:[ { from_state = "init"; on_call = "init"; to_state = "ready" } ]
  in
  match Protocol.step (Protocol.start p) ~call:"init" with
  | Ok c -> Alcotest.(check string) "moved to ready" "ready" (Protocol.current_state c)
  | Error e -> Alcotest.fail e

let test_step_rejects_a_call_invalid_from_the_current_state () =
  let p =
    Protocol.create ~states:[ "init"; "ready" ] ~initial:"init"
      ~transitions:[ { from_state = "init"; on_call = "init"; to_state = "ready" } ]
  in
  match Protocol.step (Protocol.start p) ~call:"handle" with
  | Ok _ -> Alcotest.fail "expected rejection"
  | Error e ->
    Alcotest.(check bool) "names the illegal call and the current state" true
      (String.length e > 0)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune test --force`
Expected: FAIL to compile (`Riptide_module.Protocol` does not exist yet).

- [ ] **Step 3: Implement `lib/module/protocol.ml`/`.mli`**

```ocaml
type state = string
type transition = { from_state : state; on_call : string; to_state : state }
type t

val create : states:state list -> initial:state -> transitions:transition list -> t
(** @raise Invalid_argument if [initial] is not in [states], if any transition's [from_state] or
    [to_state] is not in [states], or if two transitions share the same [(from_state, on_call)]
    pair (a nondeterministic protocol). *)

type checker

val start : t -> checker
val step : checker -> call:string -> (checker, string) result
val current_state : checker -> state
```

`lib/module/dune`:
```dune
(library
 (name riptide_module))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dune test --force`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/module/ test/test_module_protocol.ml test/dune
git commit -m "module: add the hand-rolled session-type protocol FSM (Task 5, subtask 2)"
```

---

### Task 2: Universal authorization checkpoint in `Batch_commit`

**Files:**
- Modify: `lib/batch_commit/batch_commit.ml`
- Modify: `lib/batch_commit/batch_commit.mli`
- Modify: every existing call site of `Batch_commit.create` (found via `grep -rn "Batch_commit.create" lib/ test/ explore/`) to pass the new required `~authorize` argument — expect roughly 40 sites, per Task 27's own real migration of this same magnitude.
- Test: `test/test_batch_commit.ml` (extend)

**Interfaces:**
- Consumes: `Batch_commit.write`, `Batch_commit.create`, `Batch_commit.propose` (all pre-existing; exact current signatures are in `lib/batch_commit/batch_commit.mli`).
- Produces: `Batch_commit.decision` (`Allow | Deny of string`), `Batch_commit.allow_all : write -> decision`, `Batch_commit.authorization_denials : unit -> int` — consumed by Task 6 (reactor wiring, which supplies a real `authorize`) and by every existing call site (which passes `allow_all` until Layer 2 has a real policy).

- [ ] **Step 1: Write the failing tests**

```ocaml
let test_propose_refuses_the_whole_batch_when_any_write_is_denied () =
  with_cluster ~replica_count:1 (fun ~replicas ~settle:_ ->
      let deny_second = ref false in
      let authorize (w : Batch_commit.write) =
        if !deny_second && w.merge_key = Some "b" then Batch_commit.Deny "test denial"
        else Batch_commit.Allow
      in
      let t = Batch_commit.create ~replica:replicas.(0) ~authorize () in
      Batch_commit.propose t ~idempotency_key:"k1"
        [
          { actor = "a"; causation = h "c1"; correlation = h "c1"; payload = v "1"; merge_key = Some "a" };
          { actor = "a"; causation = h "c1"; correlation = h "c1"; payload = v "2"; merge_key = Some "b" };
        ];
      deny_second := true;
      let before = Batch_commit.authorization_denials () in
      Batch_commit.propose t ~idempotency_key:"k2"
        [
          { actor = "a"; causation = h "c2"; correlation = h "c2"; payload = v "3"; merge_key = Some "a" };
          { actor = "a"; causation = h "c2"; correlation = h "c2"; payload = v "4"; merge_key = Some "b" };
        ];
      Alcotest.(check int) "denial counted" (before + 1) (Batch_commit.authorization_denials ());
      Alcotest.(check bool) "the whole batch was refused, not just the denied write" true
        (List.length (Batch_commit.committed_envelopes replicas.(0)) = 2
        (* only k1's two writes ever committed *)))

let test_allow_all_is_the_explicit_no_policy_choice () =
  (* every existing test/call site's own use of Batch_commit.create ~authorize:Batch_commit.allow_all
     continues to behave exactly as it did before this task -- pinned once here, not re-asserted
     at every migrated call site *)
  with_cluster ~replica_count:1 (fun ~replicas ~settle:_ ->
      let t = Batch_commit.create ~replica:replicas.(0) ~authorize:Batch_commit.allow_all () in
      Batch_commit.propose t ~idempotency_key:"k"
        [ { actor = "a"; causation = h "c"; correlation = h "c"; payload = v "1"; merge_key = None } ];
      Alcotest.(check int) "committed" 1 (List.length (Batch_commit.committed_envelopes replicas.(0))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune test --force`
Expected: FAIL to compile (`authorize` is not a recognized label; `Deny`/`Allow`/`allow_all`/`authorization_denials` do not exist).

- [ ] **Step 3: Implement in `lib/batch_commit/batch_commit.ml`/`.mli`**

Add:
```ocaml
type decision = Allow | Deny of string

val allow_all : write -> decision
(** The explicit, visible "no real policy yet" choice — every call site must pass something, and
    this is the honest default until a real Layer 2 policy exists. *)

val authorization_denials : unit -> int
(** Shaped exactly like {!materialize_write_failures}: a monotonic, process-lifetime count, never
    reset. The useful reading is a delta between two samples, not an absolute value in isolation. *)
```

Change `create`'s signature to:
```ocaml
val create : replica:Riptide_vsr.Replica.t -> authorize:(write -> decision) -> ?require_encryption:bool -> unit -> t
```

In `propose`, before the existing idempotency-key/commit-membership check, evaluate `authorize w`
for every `w` in the batch. If any returns `Deny reason`, increment `authorization_denials`'s
backing counter and return without proposing anything (the same silent-no-op convention every
other guard failure in this function already uses) — the whole batch is refused, since a batch is
one atomic, indivisible unit. If every write is `Allow`, append one additional synthetic `write` to
the list actually passed to `Riptide_vsr.Replica.propose`, recording the decision as a real,
causally-linked envelope: `actor = "riptide.module.authz"`, `causation`/`correlation` copied from
the batch's own first write, `merge_key = None`, `payload` encoding the decision (your choice of
shape — the batch's `idempotency_key` and the fact it was allowed is the minimum useful content).

- [ ] **Step 4: Update every existing call site**

`grep -rn "Batch_commit.create" lib/ test/ explore/` and add `~authorize:Batch_commit.allow_all` to
each (this is the "every real call site" migration Task 27 already did once for `Batch_commit.t`
itself, at the same real magnitude).

- [ ] **Step 5: Run tests to verify they pass**

Run: `dune build @all && dune test --force`
Expected: PASS, full suite green.

- [ ] **Step 6: Commit**

```bash
git add lib/batch_commit/ test/
git commit -m "batch_commit: add a universal, mandatory authorization checkpoint (Task 5, subtask 5)"
```

---

### Task 3: WASM loader — instantiation, host ABI, SFI isolation

**Files:**
- Create: `lib/module/loader.ml`
- Create: `lib/module/loader.mli`
- Create: `test/fixtures/echo.wat` (a hand-written WAT guest: imports `log`, exports `handle` which calls `log` once and returns)
- Create: `test/fixtures/runaway.wat` (a hand-written WAT guest: an infinite loop in `handle`, to prove fuel exhaustion contains it)
- Test: `test/test_module_loader.ml`

**Interfaces:**
- Consumes: nothing from Tasks 1-2 yet (Protocol enforcement is Task 4).
- Produces: `Riptide_module.Loader.host_functions`, `instantiate`, `invoke`, `Isolation_tier` — consumed by Task 4 (protocol enforcement wraps `invoke`) and Task 6 (reactor calls `instantiate`/`invoke`).

- [ ] **Step 1: Write the failing tests**

```ocaml
let test_invoke_calls_the_guests_handle_and_observes_its_log_call () =
  let logged = ref [] in
  let host = { Loader.read_materialized = (fun ~merge_key:_ -> None);
               propose_write = (fun _ -> Ok ());
               log = (fun s -> logged := s :: !logged) } in
  let m = Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "test/fixtures/echo.wat") ~host in
  (match Loader.invoke m ~entrypoint:"handle" ~arg:Bytes.empty with
  | Ok _ -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check (list string)) "guest logged once" [ "hello" ] !logged

let test_a_runaway_module_is_contained_not_crashing_the_host () =
  let host = { Loader.read_materialized = (fun ~merge_key:_ -> None);
               propose_write = (fun _ -> Ok ());
               log = (fun _ -> ()) } in
  let m = Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "test/fixtures/runaway.wat") ~host in
  match Loader.invoke m ~entrypoint:"handle" ~arg:Bytes.empty with
  | Ok _ -> Alcotest.fail "expected containment, not success"
  | Error e -> Alcotest.(check bool) "fuel exhaustion is reported, not a host crash" true (String.length e > 0)

let test_microvm_tier_raises_a_clear_not_implemented_error () =
  Alcotest.check_raises "microvm tier is designed, not built"
    (Failure "Loader.instantiate: Microvm tier is not yet implemented (Task 8's own job)")
    (fun () ->
      ignore
        (Loader.instantiate ~tier:Loader.Microvm ~module_bytes:(read_file "test/fixtures/echo.wat")
           ~host:{ Loader.read_materialized = (fun ~merge_key:_ -> None); propose_write = (fun _ -> Ok ()); log = ignore }))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune test --force`
Expected: FAIL to compile (`Riptide_module.Loader` does not exist yet).

- [ ] **Step 3: Implement `lib/module/loader.ml`/`.mli`**

Add `wasmtime` to `lib/module/dune`'s `libraries`.

```ocaml
type isolation_tier = Sfi | Microvm

type host_functions = {
  read_materialized : merge_key:string -> bytes option;
  propose_write : bytes -> (unit, string) result;
  log : string -> unit;
}

type t

val instantiate : tier:isolation_tier -> module_bytes:string -> host:host_functions -> t
(** One fresh instance, never reused. [tier = Microvm] @raise Failure "Loader.instantiate: Microvm
    tier is not yet implemented (Task 8's own job)" — a real, tested error, not silent
    acceptance of an unbuilt capability. Applies wasmtime's own fuel and linear-memory limits so a
    module cannot loop forever or grow memory unbounded; see the spec's Decision 5 for the exact
    isolation properties this must hold (never shared heap, never reused instance). *)

val invoke : t -> entrypoint:string -> arg:bytes -> (bytes, string) result
```

One line on the approach: use `wasmtime`'s `Store`/`Instance` API with a fuel limit consumed per
instruction (wasmtime's own built-in mechanism) and a linear-memory page limit set at instantiation;
`propose_write`'s `bytes -> (unit, string) result` shape matches `host_functions`' own error
convention rather than raising, so a guest's proposal failure is always observable to `invoke`'s
own caller.

- [ ] **Step 4: Run tests to verify they pass**

Run: `dune build @all && dune test --force`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/module/loader.ml lib/module/loader.mli lib/module/dune test/fixtures/ test/test_module_loader.ml
git commit -m "module: WASM loader with SFI isolation and a designed (not built) microVM tier (Task 5, subtask 1+3)"
```

---

### Task 4: Enforce the protocol FSM inside the loader

**Files:**
- Modify: `lib/module/loader.ml`
- Modify: `lib/module/loader.mli`
- Create: `test/fixtures/protocol_violator.wat` (a guest that calls `propose_write` before `init`)
- Test: `test/test_module_loader.ml` (extend)

**Interfaces:**
- Consumes: `Riptide_module.Protocol.t`/`create`/`start`/`step`/`current_state` (Task 1).
- Produces: `Loader.instantiate` gains a `~protocol:Protocol.t` argument — consumed by Task 6.

- [ ] **Step 1: Write the failing tests**

```ocaml
let test_a_call_violating_the_declared_protocol_is_rejected_not_forwarded_to_the_guest () =
  let called = ref false in
  let host = { Loader.read_materialized = (fun ~merge_key:_ -> None);
               propose_write = (fun _ -> called := true; Ok ());
               log = (fun _ -> ()) } in
  let protocol =
    Protocol.create ~states:[ "init"; "ready" ] ~initial:"init"
      ~transitions:[ { from_state = "init"; on_call = "init"; to_state = "ready" } ]
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "test/fixtures/protocol_violator.wat")
      ~host ~protocol
  in
  match Loader.invoke m ~entrypoint:"handle" ~arg:Bytes.empty with
  | Ok _ -> Alcotest.fail "expected rejection"
  | Error _ ->
    Alcotest.(check bool) "the guest's own propose_write was never reached" false !called

let test_two_concurrent_invocations_of_the_same_module_do_not_share_protocol_state () =
  let host = { Loader.read_materialized = (fun ~merge_key:_ -> None); propose_write = (fun _ -> Ok ());
               log = (fun _ -> ()) } in
  let protocol =
    Protocol.create ~states:[ "init"; "ready" ] ~initial:"init"
      ~transitions:[ { from_state = "init"; on_call = "init"; to_state = "ready" } ]
  in
  let module_bytes = read_file "test/fixtures/echo.wat" in
  let m1 = Loader.instantiate ~tier:Loader.Sfi ~module_bytes ~host ~protocol in
  let m2 = Loader.instantiate ~tier:Loader.Sfi ~module_bytes ~host ~protocol in
  (* m1 progresses its own protocol; m2, freshly instantiated, must still start at "init" *)
  ignore (Loader.invoke m1 ~entrypoint:"init" ~arg:Bytes.empty);
  match Loader.invoke m2 ~entrypoint:"handle" ~arg:Bytes.empty with
  | Ok _ -> Alcotest.fail "m2 should still be at its own fresh initial state"
  | Error _ -> ()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune test --force`
Expected: FAIL to compile (`instantiate` does not accept `~protocol` yet).

- [ ] **Step 3: Implement**

`instantiate`'s signature gains `~protocol:Riptide_module.Protocol.t`. Each `t` owns its own fresh
`Protocol.checker` (via `Protocol.start`), created once at instantiation — never shared across
`t` values, satisfying the Review Focus item on concurrent-invocation isolation by construction,
since `instantiate` already creates a fresh `t` per invocation (Task 3). `invoke` calls
`Protocol.step` on the entrypoint name before forwarding the call into the guest; on `Error _`,
`invoke` returns that error immediately, without ever entering guest code (matching this
codebase's own "guard failure ⇒ total no-op" convention — the guest is never given a chance to
observe a call it wasn't supposed to make).

- [ ] **Step 4: Run tests to verify they pass**

Run: `dune build @all && dune test --force`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/module/loader.ml lib/module/loader.mli test/fixtures/protocol_violator.wat test/test_module_loader.ml
git commit -m "module: enforce the declared session-type protocol at call time (Task 5, subtask 2)"
```

---

### Task 5: Admission gate

**Files:**
- Create: `lib/module/admission.ml`
- Create: `lib/module/admission.mli`
- Test: `test/test_module_admission.ml`

**Interfaces:**
- Consumes: `Riptide_module.Loader.isolation_tier` (Task 3).
- Produces: `Admission.verify`, `Admission.verified_artifact` (carries the artifact's local path and its recorded `isolation_tier`) — consumed by Task 6 (reactor only ever loads a `verified_artifact`, never a bare path).

- [ ] **Step 1: Write the failing tests**

```ocaml
let test_verify_rejects_when_cosign_is_not_on_path () =
  match Admission.verify ~cosign_path:"/nonexistent/cosign" ~digest:"sha256:deadbeef"
          ~tier:Loader.Sfi ~artifact_path:"/tmp/whatever" with
  | Ok _ -> Alcotest.fail "expected a closed-fail rejection"
  | Error _ -> ()

let test_verify_accepts_a_real_locally_signed_artifact () =
  (* Test setup: generate a real cosign keypair (cosign generate-key-pair, in a tmp dir),
     cosign sign-blob a real local file, then Admission.verify against that same local key --
     no live Sigstore/Fulcio/Rekor network dependency, matching the spec's own named open question
     resolved here as: local keypair signing for tests, real keyless/Fulcio flow left to
     deployment-time configuration this task does not need to exercise. *)
  let dir = Filename.temp_dir "admission_test" "" in
  let artifact = Filename.concat dir "module.wasm" in
  write_file artifact "fake wasm bytes";
  run_cosign [ "generate-key-pair" ] ~cwd:dir;
  run_cosign [ "sign-blob"; "--key"; Filename.concat dir "cosign.key"; "--yes"; artifact ] ~cwd:dir;
  match
    Admission.verify ~cosign_path:"cosign" ~key:(Filename.concat dir "cosign.pub")
      ~digest:(sha256_hex artifact) ~tier:Loader.Sfi ~artifact_path:artifact
  with
  | Ok v -> Alcotest.(check Loader.isolation_tier_testable) "tier recorded" Loader.Sfi v.tier
  | Error e -> Alcotest.fail e

let test_verify_rejects_a_tampered_artifact () =
  (* same setup as above, then the artifact's bytes are modified after signing *)
  ...
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune test --force`
Expected: FAIL to compile (`Riptide_module.Admission` does not exist yet).

- [ ] **Step 3: Implement `lib/module/admission.ml`/`.mli`**

```ocaml
type verified_artifact = { local_path : string; tier : Loader.isolation_tier }

val verify :
  cosign_path:string ->
  ?key:string ->
  digest:string ->
  tier:Loader.isolation_tier ->
  artifact_path:string ->
  (verified_artifact, string) result
```

One line on the approach: shell out to `cosign verify-blob --key <key> --signature <path.sig>
<artifact_path>` (or the keyless/Fulcio form when `?key` is omitted — your reasonable choice which
one this task's own tests exercise, per the spec's disclosed open question on live-vs-local Sigstore
in CI) via `Unix.open_process_args`; a nonzero exit or the binary missing from `cosign_path` both
return `Error _` — never `Ok`, matching the Review Focus item on failing closed. Content-digest
mismatch (the artifact's real SHA-256 vs. the `~digest` the caller expected) is checked in OCaml
before ever invoking `cosign`, since that check needs no external tool.

- [ ] **Step 4: Run tests to verify they pass**

Run: `dune build @all && dune test --force`
Expected: PASS. (Requires `cosign` on `PATH` — if unavailable in this environment, install it per
its own release instructions before running this task's tests; do not skip or stub the check.)

- [ ] **Step 5: Commit**

```bash
git add lib/module/admission.ml lib/module/admission.mli test/test_module_admission.ml
git commit -m "module: admission gate shells out to real cosign for signature+provenance (Task 5, subtask 4)"
```

---

### Task 6: Reactor dispatch loop

**Files:**
- Create: `lib/module/reactor.ml`
- Create: `lib/module/reactor.mli`
- Test: `test/test_module_reactor.ml`

**Interfaces:**
- Consumes: `Riptide_module.Admission.verified_artifact` (Task 5), `Riptide_module.Loader.instantiate`/`invoke` (Tasks 3-4), `Riptide_module.Protocol.t` (Task 1), `Batch_commit.materialize_sink` (existing), `Batch_commit.propose`/`create`/`write`/`decision` (Task 2).
- Produces: `Reactor.subscribe`, `Reactor.wrap_materialize_sink` — consumed by whatever future call site wires a real `Batch_commit`-driven deployment together (out of this task's own scope to build that call site; Task 6 only needs to prove the wrapping and dispatch work).

- [ ] **Step 1: Write the failing tests**

Shared setup, used by every test below: `verified_echo ()` runs `test/fixtures/echo.wat` through
`Admission.verify` (Task 5) against a locally-signed test artifact, returning its
`verified_artifact`; `allow_handle_from_init` is `Protocol.create ~states:[ "init"; "ready" ]
~initial:"init" ~transitions:[ { from_state = "init"; on_call = "handle"; to_state = "ready" } ]`
(Task 1) — the same shape Task 4's own tests already use for a protocol permitting exactly one
call to `handle`.

```ocaml
let test_a_materialized_change_on_a_subscribed_key_invokes_the_module () =
  let invoked = ref [] in
  let inner_sink : Batch_commit.materialize_sink =
    { write = (fun ~merge_key v -> invoked := (`inner, merge_key, v) :: !invoked) }
  in
  let reactor = Reactor.create () in
  let read ~merge_key:_ = None and propose _ = Ok () in
  Reactor.subscribe reactor ~merge_key:"k" ~module_:(verified_echo ()) ~protocol:allow_handle_from_init
    ~read ~propose;
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  wrapped.write ~merge_key:"k" (v "1");
  Alcotest.(check bool) "inner sink still ran" true
    (List.exists (fun (tag, _, _) -> tag = `inner) !invoked)
  (* plus: assert the module's own handle was actually invoked -- via its host_functions.log
     callback recording a call, the same observable Task 3 already established *)

let test_a_change_on_an_unsubscribed_key_never_invokes_any_module () =
  let reactor = Reactor.create () in
  let inner_sink : Batch_commit.materialize_sink = { write = (fun ~merge_key:_ _ -> ()) } in
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  (* no subscription registered *)
  wrapped.write ~merge_key:"unrelated" (v "1")
  (* no exception, no module invocation -- nothing to assert beyond "this doesn't raise" *)

let test_a_module_that_calls_propose_write_zero_times_is_not_an_error () =
  (* Review Focus: a module legitimately choosing not to act must be a clean no-op, not a
     reactor-level failure. echo.wat's own handle only logs -- it never calls propose_write. *)
  let proposed = ref 0 in
  let read ~merge_key:_ = None and propose _ = incr proposed; Ok () in
  let reactor = Reactor.create () in
  let inner_sink : Batch_commit.materialize_sink = { write = (fun ~merge_key:_ _ -> ()) } in
  Reactor.subscribe reactor ~merge_key:"k" ~module_:(verified_echo ()) ~protocol:allow_handle_from_init
    ~read ~propose;
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  wrapped.write ~merge_key:"k" (v "1");
  Alcotest.(check int) "propose was never called, and nothing raised" 0 !proposed

let test_one_subscribed_modules_denial_does_not_affect_a_sibling_module_on_the_same_key () =
  (* two modules subscribed to the same merge_key, wired to two DIFFERENT Batch_commit.t handles
     -- one whose authorize always Denies, one whose authorize always Allows -- both dispatched
     from the same materialized change; assert the Allow-wired module's write committed and the
     Deny-wired module's did not, independently *)
  ...
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune test --force`
Expected: FAIL to compile (`Riptide_module.Reactor` does not exist yet).

- [ ] **Step 3: Implement `lib/module/reactor.ml`/`.mli`**

```ocaml
type t

val create : unit -> t

val subscribe :
  t ->
  merge_key:string ->
  module_:Admission.verified_artifact ->
  protocol:Protocol.t ->
  read:(merge_key:string -> bytes option) ->
  propose:(bytes -> (unit, string) result) ->
  unit
(** [read]/[propose] are the caller's responsibility to wire to a real
    {!Riptide_materialize.Materializer.read} and {!Batch_commit.propose} call (with whatever
    {!Batch_commit.t} handle that deployment's own [authorize] policy is attached to) — this
    module has no opinion on which concrete materializer or handle a given subscription uses, the
    same "erased sink" pattern {!Batch_commit.materialize_sink}/[encryption_sink] already
    establish. [Loader.host_functions]'s own [log] field is filled in internally by the reactor,
    not exposed here — nothing about a subscription needs to customize it. *)

val wrap_materialize_sink : t -> Batch_commit.materialize_sink -> Batch_commit.materialize_sink
(** Returns a sink that calls the wrapped [inner]'s own [write] first (materialization itself is
    never skipped or reordered), then dispatches to every module subscribed to that [merge_key],
    each in its own fresh {!Loader.instantiate}. *)
```

One line on the approach: `subscribe` stores its `merge_key -> module_ list` mapping in a
`Hashtbl.t` inside `t`; `wrap_materialize_sink`'s returned `write` looks up subscribers for the
given `merge_key` after calling `inner.write`, and for each, calls `Loader.instantiate` (Task 3-4)
fresh, then `Loader.invoke ~entrypoint:"handle" ~arg:(encoded materialized value)` — a module
invocation's own failure (a trap, a protocol violation) must not raise out of `wrap_materialize_sink`'s
`write` and must not prevent any *other* subscribed module (on this key or triggered by this same
underlying commit) from running; log it and continue, matching the Review Focus item on
independence between sibling modules.

- [ ] **Step 4: Run tests to verify they pass**

Run: `dune build @all && dune test --force`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/module/reactor.ml lib/module/reactor.mli test/test_module_reactor.ml
git commit -m "module: reactor dispatch loop wraps materialize_sink to invoke subscribed modules (Task 5, subtask 1+5)"
```

---

### Task 7: End-to-end integration test

**Files:**
- Create: `test/fixtures/counter.wat` (a real guest: `handle` reads its own subscribed key via `read_materialized`, adds 1, calls `propose_write` with the result)
- Test: `test/test_module_end_to_end.ml`

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: nothing new — this task proves the whole boundary works together, exactly as Decision 1/2's data flow describes.

- [ ] **Step 1: Write the failing test**

```ocaml
let test_a_real_module_reacts_commits_and_can_retrigger_itself () =
  (* Full path: a real Batch_commit.t (authorize = allow_all), a real single-replica cluster, a
     real Materializer, admission-verified counter.wat subscribed to merge_key "count". Propose an
     initial write to "count" through Batch_commit.propose with ?materialize wrapped by
     Reactor.wrap_materialize_sink. Assert: the module's own handle ran (observable via its log
     host function), its propose_write reached the real replica (Batch_commit.committed_envelopes
     shows a new envelope with the incremented value), and -- since that new commit itself
     re-materializes -- the module runs AGAIN on its own output, observable as a second log call,
     bounded by a fixed retrigger count in the test so it terminates rather than looping forever. *)
  ...
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force`
Expected: FAIL (either a compile error if any Task 1-6 interface was used incorrectly, or a real
assertion failure if the wiring doesn't actually connect end to end — either is useful signal here).

- [ ] **Step 3: Make it pass**

This task should require no new library code if Tasks 1-6 are correctly composed — only test code
wiring their existing interfaces together. If it reveals a real gap in an earlier task's interface,
fix that task's own file directly (per this project's own "no spec without running code" — an
interface that doesn't actually compose is a defect in the task that shipped it, not a new task).

- [ ] **Step 4: Run test to verify it passes**

Run: `dune build @all && dune test --force`
Expected: PASS, full suite green.

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/counter.wat test/test_module_end_to_end.ml
git commit -m "module: end-to-end proof the Layer 0/Layer 2 boundary works together (Task 5)"
```
