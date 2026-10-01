# Layer 2 Ledger Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a real, demanding double-entry ledger as riptide's first Layer 2 module — a WASM
guest enforcing a sufficient-funds business rule, a host-side authorization checkpoint enforcing
the ledger's own structural invariant, and a DST-driven production-shaped load test with injected
node failures — pressure-testing the Layer 0/Layer 2 boundary (task-master Task 6) end to end.

**Architecture:** Two enforcement layers. The WASM guest (`ledger.wat`) decides whether a
requested transfer should happen (reads the current balance via `read_materialized`, checks
sufficient funds) and, if approved, calls `propose_write`. The host-side `authorize` function
(wired into this module's own `Batch_commit.t`) structurally validates each resulting transfer
leg in isolation — the one property `Batch_commit`'s real `write -> decision` signature can
actually guarantee is un-bypassable. The cross-leg "both legs are a true matching pair" property
is instead guaranteed by construction in one piece of trusted host code (`Ledger.Legs`), which is
the only path from guest-controlled bytes to a `Batch_commit.write list` — verified directly by
fuzz-testing that construction, not by `authorize`.

**Tech Stack:** OCaml 5.0.0 / dune, existing `riptide`/`riptide_batch_commit`/`riptide_module`/
`riptide_materialize`/`riptide_vsr`/`riptide_dst` libraries, Alcotest, QCheck2, real `cosign`
(already installed at `/work/toolchain/bin/cosign`), hand-written `.wat` guest text.

**Spec:** `docs/superpowers/specs/2026-10-01-layer2-ledger-module-design.md`

## Global Constraints

- Domain is a double-entry ledger, focused-core scope: accounts, transfers, the balance
  invariant, real atomicity. No two-phase/pending transfers, no linked transfer chains, no
  multi-currency, no account lifecycle (open/close), no schema-morphism mechanism (Task 2.1
  remains a separate, unbuilt prerequisite — this plan does not touch it).
- Account identifiers are `int64`, not strings (spec Decision 2) — matches TigerBeetle's own
  convention and keeps the host/guest wire encoding fixed-width.
- `transfer_request.amount`/`transfer_leg.amount` are always a positive magnitude; a value `<= 0L`
  is malformed.
- Merge keys: `"ledger.requests"` for incoming requests; `"ledger.account." ^
  Int64.to_string account` for one account's materialized balance.
- Two-layer enforcement (spec Decision 1): `authorize` checks ONE write's own self-certifying
  well-formedness only — `amount > 0`, `this_account <> other_account`, merge_key matches
  `this_account`. It does NOT and architecturally CANNOT check that a matching sibling leg
  exists in the same batch (`Batch_commit.authorize`'s real signature is `write -> decision`,
  no batch visibility). That cross-leg pairing guarantee comes from construction: `Legs.legs_of_request`/
  `Legs.legs_of_bytes` always builds both legs together from one decoded request.
- Wire convention (spec Decision 3): the guest ignores `arg` (hard-wired to
  `Value.canonical_encode`, impractical to parse in hand-written WAT) and instead calls
  `read_materialized` on its own keys, using a private fixed-width LE-`int64` byte convention
  between this module's own `~read`/`~propose` closures and `ledger.wat` — not part of the
  general loader ABI. `read_materialized("ledger.requests")` returns 32 bytes (`request_id ++
  from_account ++ to_account ++ amount`); `read_materialized("ledger.account.<id>")` returns 8
  bytes (the balance) or `None` (balance 0); `propose_write` takes the same 32-byte request
  encoding back.
- The `~propose` closure's `Batch_commit.propose` call for a transfer's legs uses
  `~idempotency_key:("ledger-transfer-" ^ Int64.to_string request_id)` — deterministic from
  `request_id`, so a retried/duplicate request never double-applies.

## Review Focus

- A self-transfer request (`from_account = to_account`) must be denied by `authorize`, not
  silently treated as a net-zero no-op — Task 2.
- A transfer-leg write with a non-positive `amount` must be denied by `authorize`, regardless of
  where it came from — Task 2.
- A `"ledger.account.*"` write proposed directly, bypassing the module's own `~propose` closure
  entirely, must still be caught by `authorize` — the invariant must hold against ANY sequence of
  operations, not just module-originated ones — Task 2.
- The same `request_id` proposed twice (a retried/duplicated client request) must not
  double-apply the transfer — the account balance must reflect exactly one transfer — Task 3.
- Insufficient funds must be a clean no-op: no `propose_write` call, nothing raised, balance
  unchanged — Task 3.

---

### Task 1: Schema and wire encoding

**Files:**
- Create: `lib/ledger/schema.ml`
- Create: `lib/ledger/schema.mli`
- Create: `lib/ledger/wire.ml`
- Create: `lib/ledger/wire.mli`
- Create: `lib/ledger/dune`
- Test: `test/test_ledger_schema.ml`
- Modify: `test/dune` (add `riptide_ledger` to the single `test_riptide` executable's `libraries`
  list — dune auto-discovers every `.ml` file under `test/` as a module of that one executable, no
  per-file registration needed in `test/dune` itself)
- Modify: `test/test_riptide.ml` (register the `ledger_schema` suite)

**Interfaces:**
- Consumes: `Riptide.Value.value`/`scalar` (`lib/value.mli`) — `Record`/`Scalar (Int _)`/`Sum`
  constructors, `canonical_encode`/`canonical_decode`.
- Produces (consumed by Tasks 2-4):
  ```ocaml
  (* lib/ledger/schema.mli *)
  type role = Debit | Credit

  type transfer_request = {
    request_id : int64;
    from_account : int64;
    to_account : int64;
    amount : int64;
  }

  type transfer_leg = {
    transfer_id : int64;
    role : role;
    this_account : int64;
    other_account : int64;
    amount : int64;
  }

  val requests_merge_key : string
  val account_merge_key : int64 -> string

  val transfer_request_to_value : transfer_request -> Riptide.Value.value
  val transfer_request_of_value : Riptide.Value.value -> transfer_request option
  val transfer_leg_to_value : transfer_leg -> Riptide.Value.value
  val transfer_leg_of_value : Riptide.Value.value -> transfer_leg option
  ```
  ```ocaml
  (* lib/ledger/wire.mli *)
  val encode_request : Schema.transfer_request -> bytes   (* exactly 32 bytes *)
  val decode_request : bytes -> Schema.transfer_request option  (* None on wrong length *)
  val encode_balance : int64 -> bytes                      (* exactly 8 bytes *)
  val decode_balance : bytes -> int64 option                (* None on wrong length *)
  ```

- [ ] **Step 1: Write the failing tests**

```ocaml
(* test/test_ledger_schema.ml *)
open Riptide_ledger

let test_transfer_request_round_trips_through_value () =
  let r = Schema.{ request_id = 7L; from_account = 100L; to_account = 200L; amount = 5000L } in
  match Schema.transfer_request_of_value (Schema.transfer_request_to_value r) with
  | None -> Alcotest.fail "expected Some"
  | Some r' -> Alcotest.(check bool) "round trip" true (r = r')

let test_transfer_leg_round_trips_through_value () =
  let l = Schema.{ transfer_id = 7L; role = Debit; this_account = 100L; other_account = 200L; amount = 5000L } in
  match Schema.transfer_leg_of_value (Schema.transfer_leg_to_value l) with
  | None -> Alcotest.fail "expected Some"
  | Some l' -> Alcotest.(check bool) "round trip" true (l = l')

let test_transfer_leg_of_value_rejects_a_malformed_record () =
  Alcotest.(check bool) "garbage Value.value is rejected" true
    (Schema.transfer_leg_of_value (Riptide.Value.Scalar (Riptide.Value.String "not a leg")) = None)

let test_account_merge_key_format () =
  Alcotest.(check string) "exact format" "ledger.account.100" (Schema.account_merge_key 100L)

let test_wire_request_round_trips () =
  let r = Schema.{ request_id = 7L; from_account = 100L; to_account = 200L; amount = 5000L } in
  Alcotest.(check bool) "round trip" true (Wire.decode_request (Wire.encode_request r) = Some r)

let test_wire_decode_request_rejects_wrong_length () =
  Alcotest.(check bool) "31 bytes is rejected" true
    (Wire.decode_request (Bytes.make 31 '\000') = None)

let test_wire_balance_round_trips () =
  Alcotest.(check bool) "round trip" true (Wire.decode_balance (Wire.encode_balance (-42L)) = Some (-42L))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune test --force`
Expected: FAIL to compile (`Riptide_ledger.Schema`/`Wire` do not exist yet).

- [ ] **Step 3: Implement `lib/ledger/schema.ml`/`.mli`, `lib/ledger/wire.ml`/`.mli`, and `lib/ledger/dune`**

`lib/ledger/dune`:
```
(library
 (name riptide_ledger)
 (libraries riptide))
```

`schema.ml`: `transfer_request_to_value`/`transfer_leg_to_value` build a `Value.Record` with
`int64` fields as `Value.Scalar (Value.Int _)` and `role` as `Value.Sum ("Debit", Value.Scalar
(Value.Bool true))`/`Value.Sum ("Credit", Value.Scalar (Value.Bool true))` (the payload is
unused, matching this codebase's own `Sum` convention for a plain enum tag). The `_of_value`
functions do field lookup by name (`List.assoc_opt`) against an expected `Record`, matching
`write_of_value`'s own established pattern (`lib/batch_commit/batch_commit.ml`) — return `None`,
never raise, on any missing/mismatched field or wrong outer shape.

`wire.ml`: `encode_request`/`encode_balance` write `int64` fields as 8-byte little-endian via
`Bytes.set_int64_le`; `decode_request`/`decode_balance` check the input length first (`None` on
mismatch) then read back via `Bytes.get_int64_le`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `dune build @all && dune test --force`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ledger/schema.ml lib/ledger/schema.mli lib/ledger/wire.ml lib/ledger/wire.mli \
  lib/ledger/dune test/test_ledger_schema.ml test/dune test/test_riptide.ml
git commit -m "ledger: schema and host/guest wire encoding (Task 6, subtask 1+3)"
```

---

### Task 2: Leg construction and the authorization checkpoint

**Files:**
- Create: `lib/ledger/legs.ml`
- Create: `lib/ledger/legs.mli`
- Create: `lib/ledger/authorize.ml`
- Create: `lib/ledger/authorize.mli`
- Test: `test/test_ledger_authorize_fuzz.ml`
- Modify: `lib/ledger/dune` (depend on `riptide_batch_commit`)
- Modify: `test/test_riptide.ml` (register the `ledger_authorize_fuzz` suite). No `test/dune`
  change needed — `qcheck-core`/`qcheck-alcotest` and `riptide_ledger` (Task 1) are already present.

**Interfaces:**
- Consumes: `Schema.transfer_request`/`transfer_leg`/`role`/`*_to_value`/`*_of_value`/
  `account_merge_key`/`requests_merge_key` (Task 1); `Riptide_batch_commit.Batch_commit.write`
  (`actor`/`causation`/`correlation`/`payload`/`merge_key` fields), `Batch_commit.decision`
  (`Allow`/`Deny`), `Batch_commit.create`, `Batch_commit.propose`, `Batch_commit.committed_envelopes`,
  `Batch_commit.authorization_denials`; `Riptide.Envelope.actor_id`/`event_id`.
- Produces (consumed by Tasks 3-4):
  ```ocaml
  (* lib/ledger/legs.mli *)
  val legs_of_request :
    actor:Riptide.Envelope.actor_id ->
    causation:Riptide.Envelope.event_id ->
    correlation:Riptide.Envelope.event_id ->
    Schema.transfer_request ->
    Riptide_batch_commit.Batch_commit.write list

  val legs_of_bytes :
    actor:Riptide.Envelope.actor_id ->
    causation:Riptide.Envelope.event_id ->
    correlation:Riptide.Envelope.event_id ->
    bytes ->
    (Riptide_batch_commit.Batch_commit.write list, string) result
  ```
  ```ocaml
  (* lib/ledger/authorize.mli *)
  val authorize :
    Riptide_batch_commit.Batch_commit.write -> Riptide_batch_commit.Batch_commit.decision
  ```

- [ ] **Step 1: Write the failing tests**

Follow `test/test_batch_commit_authorization_fuzz.ml`'s real structure exactly (its own
`create_solo ()`/`fake_event_id`/`QCheck2.Gen` combinator style, `print_*`-for-diagnostics,
`QCheck2.Test.make ~count ~print ... |> QCheck_alcotest.to_alcotest`). Two generators, two
properties, plus three explicit named tests for the Review Focus items this task owns:

```ocaml
(* test/test_ledger_authorize_fuzz.ml *)
open Riptide_ledger

let create_solo () = (* same pattern as test_batch_commit_authorization_fuzz.ml's own helper *)
let fake_event_id n = (* same pattern *)

(* Property 1: authorize-level. A single leg write, well-formed or deliberately malformed
   (non-positive amount, same-account, merge_key/account mismatch), is generated directly --
   never routed through Legs -- and proposed alone. No malformed leg ever reaches the log. *)
let leg_gen : Schema.transfer_leg QCheck2.Gen.t = (* oneof: well-formed legs, amount <= 0, this_account = other_account *)
let test_no_malformed_leg_ever_reaches_the_log =
  QCheck2.Test.make ~name:"no malformed leg ever reaches the log" ~count:200 ~print:(...)
    leg_gen (fun leg -> (* propose [leg] directly through Batch_commit.propose with Authorize.authorize;
                            assert malformed legs never appear in committed_envelopes *) true)

(* Property 2: construction-level. Arbitrary/adversarial bytes fed into Legs.legs_of_bytes always
   produce either Error or exactly 2 well-paired, balancing legs. *)
let bytes_gen : bytes QCheck2.Gen.t = (* oneof: a real encoded request, truncated/garbage bytes *)
let test_legs_of_bytes_always_produces_nothing_or_a_balanced_pair =
  QCheck2.Test.make ~name:"legs_of_bytes: nothing or a balanced pair" ~count:200 ~print:(...)
    bytes_gen (fun b -> (* match Legs.legs_of_bytes b with
                            | Error _ -> true
                            | Ok legs -> List.length legs = 2 && (* same transfer_id, opposite deltas, distinct accounts *) *) true)

let test_a_self_transfer_request_produces_legs_authorize_denies () =
  let r = Schema.{ request_id = 1L; from_account = 5L; to_account = 5L; amount = 10L } in
  let legs = Legs.legs_of_request ~actor:"t" ~causation:(fake_event_id 0) ~correlation:(fake_event_id 0) r in
  Alcotest.(check bool) "at least one leg is denied" true
    (List.exists (fun w -> Authorize.authorize w <> Riptide_batch_commit.Batch_commit.Allow) legs)

let test_a_non_positive_amount_leg_is_denied () =
  let leg = Schema.{ transfer_id = 1L; role = Debit; this_account = 1L; other_account = 2L; amount = 0L } in
  let w = Riptide_batch_commit.Batch_commit.{ actor = "t"; causation = fake_event_id 0; correlation = fake_event_id 0;
    payload = Schema.transfer_leg_to_value leg; merge_key = Some (Schema.account_merge_key 1L) } in
  Alcotest.(check bool) "denied" true (Authorize.authorize w <> Riptide_batch_commit.Batch_commit.Allow)

let test_a_direct_unpaired_leg_write_is_denied_not_just_a_module_originated_one () =
  (* construct ONE well-formed-looking leg write directly (not via Legs), propose it ALONE
     through a real Batch_commit.t with Authorize.authorize, assert it is NOT silently accepted
     just because it looks individually valid -- restated: confirm authorize's own per-write
     checks (amount>0, distinct accounts, merge_key match) still gate it even with no sibling
     present; this is Review Focus's "any sequence of operations" bar for what authorize alone
     can enforce *)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune test --force`
Expected: FAIL to compile (`Riptide_ledger.Legs`/`Authorize` do not exist yet).

- [ ] **Step 3: Implement `lib/ledger/legs.ml` and `lib/ledger/authorize.ml`**

`legs.ml`: `legs_of_request` builds the debit leg (`this_account = from_account; other_account =
to_account`) and credit leg (`this_account = to_account; other_account = from_account`) from one
`transfer_request`, each as a `Batch_commit.write` with `merge_key = Some (Schema.account_merge_key
leg.this_account)` — see Global Constraints for the exact field derivation. `legs_of_bytes` is
`Wire.decode_request` then `legs_of_request`, returning `Error` on decode failure.

`authorize.ml`: per Global Constraints' exact branching — `"ledger.requests"` always `Allow`;
a `"ledger.account."`-prefixed merge_key decodes `Schema.transfer_leg_of_value`, `Deny`s on
decode failure/`amount <= 0`/`this_account = other_account`/merge_key-account mismatch, else
`Allow`; anything else (no merge_key, or a merge_key this module has no opinion on) is `Allow`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `dune build @all && dune test --force`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ledger/legs.ml lib/ledger/legs.mli lib/ledger/authorize.ml lib/ledger/authorize.mli \
  lib/ledger/dune test/test_ledger_authorize_fuzz.ml test/dune test/test_riptide.ml
git commit -m "ledger: leg construction and the authorization checkpoint (Task 6, subtask 2+5)"
```

---

### Task 3: The WASM guest and end-to-end module test

**Files:**
- Create: `test/fixtures/ledger.wat`
- Test: `test/test_ledger_end_to_end.ml`
- Modify: `test/dune` (add `fixtures/ledger.wat` to `(deps ...)` — every other library this test
  needs, `riptide_module`/`riptide_batch_commit`/`riptide_materialize`/`riptide_vsr`/`digestif`/
  `unix`/`riptide_ledger` (Task 1), is already present)
- Modify: `test/test_riptide.ml` (register the `ledger_end_to_end` suite)

**Interfaces:**
- Consumes: `Riptide_module.Admission.verify`/`verified_artifact`; `Riptide_module.Loader.isolation_tier`
  (`Sfi`); `Riptide_module.Protocol.create`/`transition`; `Riptide_module.Reactor.create`/
  `subscribe`/`wrap_materialize_sink`/`For_testing.log_call_count`; `Batch_commit.create`/
  `propose`/`committed_envelopes`; `Riptide_materialize.Materializer.Make`;
  `Legs.legs_of_bytes` (Task 2), `Wire.encode_request`/`decode_balance` (Task 1),
  `Schema.requests_merge_key`/`account_merge_key` (Task 1), `Authorize.authorize` (Task 2).
- Produces: nothing new — this task proves Tasks 1-2 compose against the real Layer 2 boundary,
  exactly as Task 7 of the original boundary plan proved the boundary itself composes.

- [ ] **Step 1: Write `test/fixtures/ledger.wat`**

Follow `propose_write.wat`/`counter.wat`'s exact ABI conventions (imports from `"host"`, memory
exported as `"memory"`, `handle(arg_ptr, arg_len) -> (result_ptr, result_len)`). Per Global
Constraints' wire convention, `handle` ignores its own `arg` entirely:
1. `read_materialized` on `"ledger.requests"` (32 bytes: `request_id`/`from_account`/
   `to_account`/`amount`, each an 8-byte LE `i64` — WAT guests only have native `i32`, so read
   each `i64` field as two `i32` loads, or treat the low 4 bytes as the practical value for this
   fixture's own test range and document that choice inline, matching `counter.wat`'s own
   precedent of a deliberately simple, test-scoped guest).
2. `read_materialized` on `"ledger.account." ^ string_of from_account` for the current balance (8
   bytes, same LE convention) — `None`/zero-length response means balance 0.
3. Compare `amount <= balance`. If insufficient: return without calling `propose_write` (`(i32.const
   0) (i32.const 0)`, a zero-length result, matching this codebase's own "nothing to return"
   convention from `read_materialized.wat`).
4. If sufficient: call `propose_write` with the SAME 32 bytes `read_materialized` returned for
   `"ledger.requests"` (the guest already has them in memory — just forward the same pointer/length),
   store/return its 1-byte status.

Building and hand-assembling `i64` arithmetic in WAT is more involved than the existing `i32`-only
fixtures — if full 64-bit comparison in WAT proves awkward, a documented, explicit simplification
(e.g., this fixture's own test only exercises amounts/balances that fit in 32 bits, with an inline
comment stating so) is an acceptable, disclosed scope reduction for a hand-written test fixture —
do not silently round or truncate without saying so in the `.wat` file's own comment.

- [ ] **Step 2: Write the failing tests**

Model the whole setup on `test_module_end_to_end.ml`'s real wiring sequence (helpers
`make_temp_dir`/`write_file`/`read_file`/`sha256_hex`/`run_cosign_setup`/`sign_with_fresh_keypair`/
`verified_module`/`with_tmp_dir`/`fake_event_id`/`create_solo_volatile` — copy the same pattern,
adjusted for `ledger.wat` instead of `counter.wat`):

```ocaml
(* test/test_ledger_end_to_end.ml *)
open Riptide_ledger
open Riptide_module

let allow_handle_from_init = (* same Protocol shape as test_module_end_to_end.ml's own *)
let verified_ledger () = verified_module "fixtures/ledger.wat" Loader.Sfi

let test_a_request_with_sufficient_funds_commits_both_legs_and_updates_both_balances () =
  (* real solo replica, real Batch_commit.t with ~authorize:Authorize.authorize (NOT allow_all --
     this is the first task in this plan to use the real policy end to end), real Materializer,
     real Reactor wired with ~read/~propose closures built from Wire.encode_request/decode_balance
     and Legs.legs_of_bytes, real admission-verified ledger.wat subscribed to "ledger.requests".
     Seed account 100 with an initial balance (e.g. propose a transfer_leg write directly to give
     it starting funds, OR propose two seed transfers from a conceptually-unlimited "genesis"
     account -- implementer's choice, document which). Propose a real transfer_request for less
     than the balance. Assert: both legs appear in committed_envelopes with the right deltas;
     final balance of both accounts (via read_materialized / Materializer.read) is correct. *)

let test_insufficient_funds_is_a_clean_no_op () =
  (* propose a transfer_request exceeding the balance; assert NO new ledger.account.* envelope
     appears in committed_envelopes after dispatch, Reactor.For_testing.log_call_count still
     increased by exactly 1 (the module DID run), and no exception/Error propagated out of
     wrap_materialize_sink's write *)

let test_the_same_request_id_proposed_twice_does_not_double_apply () =
  (* propose the identical transfer_request bytes/idempotency_key for "ledger.requests" TWICE
     (simulating a client retry); assert the account balance reflects the transfer exactly ONCE,
     and committed_envelopes shows exactly 2 ledger.account.* envelopes for this transfer_id, not 4 *)
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `dune test --force`
Expected: FAIL (compile error if `ledger.wat`'s ABI doesn't match what the test closures expect, or
a real assertion failure if the wiring doesn't connect end to end — either is useful signal, per
this project's own established convention from Task 7 of the boundary plan).

- [ ] **Step 4: Make it pass**

Wire the `~read`/`~propose` closures: `~read` decodes the requested `merge_key` via
`Materializer.read` and re-encodes via `Wire.encode_request`/`Wire.encode_balance` depending on
which key was asked for; `~propose` calls `Legs.legs_of_bytes` then
`Batch_commit.propose handle ~idempotency_key:("ledger-transfer-" ^ ...) ~materialize:wrapped_sink
legs` per Global Constraints' exact idempotency-key convention. If `ledger.wat` itself needs
revision to match real `Loader`/ABI behavior, fix it directly (same "fix the earlier artifact, not
a new task" principle Task 7 of the boundary plan already established).

- [ ] **Step 5: Run tests to verify they pass**

Run: `dune build @all && dune test --force`
Expected: PASS, full suite green. Run at least twice; follow each with a zombie-process check
(`ps -eo pid,ppid,stat,cmd | awk '$3 ~ /Z/'`, must be empty) — this test drives real
`Loader.instantiate`/`invoke` (fork-based), the highest-scrutiny code path in this whole project.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/ledger.wat test/test_ledger_end_to_end.ml test/dune test/test_riptide.ml
git commit -m "ledger: the WASM guest and a real end-to-end module test (Task 6, subtask 4)"
```

---

### Task 4: Production-shaped load under DST with injected node failures

**Files:**
- Test: `test/test_ledger_dst_load.ml`
- Modify: `test/test_riptide.ml` (register the `ledger_dst_load` suite). No `test/dune` change
  needed — `riptide_dst`/`riptide_sim` are already present.

**Interfaces:**
- Consumes: `Riptide_dst.Cluster.run`/`run_on_file_storage`, `Riptide_sim.Network.fault_config`,
  everything Task 3 already wired (`Legs`/`Authorize`/`Wire`/`Schema`, the `verified_ledger`/
  `allow_handle_from_init` helpers — reimplemented locally in this test file per this codebase's
  own established per-test-file-helpers convention, not factored into a shared module).
- Produces: nothing new — this is subtask 6.4's own deliverable, the real pressure test.

- [ ] **Step 1: Write the failing test**

Model on `test_dst_scenarios.ml`'s real crash/restart precedent
(`test_a_crash_with_a_torn_superblock_refuses_to_come_back`) and network-fault precedent
(`test_file_storage_cluster_committed_entries_are_durable`), combined with Task 3's own real
ledger wiring:

```ocaml
(* test/test_ledger_dst_load.ml *)
let test_the_ledger_invariant_holds_under_injected_failures () =
  (* real replica_count=3 cluster via Riptide_dst.Cluster.run, a real admission-verified
     ledger.wat (signed once at the top of this test, not per-request), real Batch_commit.t with
     Authorize.authorize on the primary, real Materializer, real Reactor wired exactly as Task 3.
     Drive many (e.g. 50+) transfer requests across several accounts with a realistic mix of
     sufficient/insufficient-funds cases (not hand-picked happy-path-only), interleaved with
     `restart`/network-fault injection via net_fault_config (drop/duplicate/delay, matching the
     real precedent's fault_config values) mid-run -- specifically including at least one crash
     timed to land between a request materializing and its propose_write landing, not just
     "crashes happen sometime."
     After settle(): assert (a) EVERY committed ledger.account.* envelope independently satisfies
     Authorize.authorize's own check (re-run it against committed_envelopes directly -- the
     structural invariant must hold for real, not just "nothing was denied"); (b) every account's
     final materialized balance equals a reference model's own independently-computed sum of all
     ACCEPTED transfers' deltas (built by the test itself, tracking what SHOULD have applied);
     (c) no transfer is lost or double-applied despite the injected failures (same idempotency-key
     reasoning as Task 3's own duplicate-request test, now under real multi-node crash/restart). *)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force`
Expected: FAIL (compile error, or a real assertion failure — useful signal either way).

- [ ] **Step 3: Make it pass**

This task should require no new library code if Tasks 1-3 are correctly composed — only test code
driving their existing interfaces through the DST harness. If it reveals a real compositional gap
(e.g. something in `Legs`/`Authorize`/the `~read`/`~propose` wiring that only breaks under real
multi-node timing), fix that task's own file directly, per this project's own "no spec without
running code" convention — an interface that doesn't actually compose under real load is a defect
in the task that shipped it, not license for new, unplanned abstraction.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune build @all && dune test --force`
Expected: PASS, full suite green. Run at least twice, zombie-process check clean after each
(`ps -eo pid,ppid,stat,cmd | awk '$3 ~ /Z/'`).

- [ ] **Step 5: Commit**

```bash
git add test/test_ledger_dst_load.ml test/dune test/test_riptide.ml
git commit -m "ledger: production-shaped load under DST with injected node failures (Task 6, subtask 4)"
```
