# Deep Audit Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all 33 design decisions in the audit-remediation spec — six of them closing Critical, live-reproduced findings — so Riptide's value codec, VSR consensus/replication, storage, materializer/lattice, and transport/crypto layers are adversarially robust, not just documented-behavior-correct.

**Architecture:** No new subsystem. Each task is a targeted fix inside an existing module, paired with a real regression test reproducing the finding it closes (this repo's "no spec without running code" rule). Tasks are grouped in the spec's own 1.1-7.5 order; within a group, later tasks may depend on an earlier one's signature change (called out per-task in Interfaces).

**Tech Stack:** OCaml 5.0.0, dune, Eio, Alcotest — the existing stack, unchanged.

**Spec:** `docs/superpowers/specs/2026-09-29-audit-remediation-design.md`

## Global Constraints

- **No spec without running code** (`CLAUDE.md`): every task's fix ships with a real, running regression test in the same commit — never a doc-only claim.
- **No production binary exists** (no `bin/` entrypoint): every wire-format or on-disk-format-breaking change in this plan (Tasks 3, 25) needs no migration tooling — only test-fixture updates.
- **No new `Kv_store_intf.S` implementer is anticipated** — `File_kv_store` is the only real implementer; don't design Task 24's `fold` for a hypothetical second backend.
- **Never use git worktrees on this box** — all work happens directly on a feature branch (`audit-remediation`) in this existing `/work/riptide` checkout, never on `main` directly.
- **Fix every review finding yourself before presenting the finishing-branch menu**, for every severity, not just Critical/Important (standing operator preference) — applies to every task review and the final whole-branch review this plan ends with.
- **The full suite must stay green throughout:** `dune build @all && dune test --force` from `/work/riptide`, after every task, before every commit.
- **Task-master status is derived, never asserted:** each subtask under task 12 moves to `done` only with a real `evidence.commits` array once its task's commit(s) land; task 12's own parent status is never hand-set.

## Review Focus

- **A malicious peer holding a valid-but-wrong-identity certificate.** Tasks 1-4 close the sender-authentication gap — the test proving it must be a real cross-process reproduction (real `Riptide_pki.Ca` certs, real `Tcp` connections, an impersonator process), not a mocked unit test, mirroring exactly how the audit itself found the original gap.
- **Concurrent access under real Eio fiber concurrency**, not simulated sequentially. Tasks 20 (materializer lock) and 15 (temp-file randomization) both fix races; their tests must drive genuinely concurrent fibers/processes, the same way the audit's own reproductions did, or the fix could look proven while the race survives.
- **Restart/crash-recovery interaction with every storage fix.** Tasks 9, 12, 17, 18 all touch crash/restart paths; each needs a test that actually restarts a `File_storage`/`File_kv_store`/`Replica` over the fixed-up on-disk state, not just an in-process assertion.
- **Old-format bytes after a wire/on-disk format change.** Tasks 3 (message wire format) and 27 (redaction record format) must make old-shaped input fail loudly (a clear decode error) rather than silently misparse — test this directly, not just the new format's happy path.
- **Resource-exhaustion inputs at real scale**, not toy sizes. Task 8 (decode budget) and Task 30 (connection cap) must be tested against inputs sized close to what the audit actually used to trigger the original findings (hundreds of KB of adversarial wire bytes; hundreds of stalled connections) — a test with 3 elements proves nothing about a bug that needed thousands to manifest.

---

## Group 1: Sender-authenticated transport + consensus forgery closure

### Task 1: `Transport_intf.S.receive` returns the authenticated sender; `Tcp` binds it to the TLS certificate

**Files:**
- Modify: `lib/transport/transport_intf.ml` (`receive` signature)
- Modify: `lib/transport/tcp.ml` (`receive`, `reader_body`, `run_connection`, `handle_accepted`)
- Modify: `lib/transport/tcp.mli`
- Modify: `lib/sim/sim_transport.ml`, `lib/sim/sim_transport.mli`
- Test: `test/test_transport_shared.ml`, `test/test_transport_tcp.ml`

**Interfaces:**
- Produces: `val receive : t -> string * int` (payload, authenticated sender peer id) — replaces `val receive : t -> string` in `Transport_intf.S`, consumed by every later task in this group and by `Replica.handle_message`'s caller (Task 3).

- [ ] **Step 1: Write the failing test**

In `test/test_transport_shared.ml` (the file already shared by both `Sim_transport` and `Tcp`'s conformance suite per the audit's own note that this file exists for exactly this purpose), add:

```ocaml
let test_receive_returns_the_authenticated_sender_id (module T : TRANSPORT_UNDER_TEST) () =
  (* two real endpoints, id 1 sends to id 2; id 2's receive must report sender = 1 *)
  let payload, sender = T.receive receiver_handle in
  Alcotest.(check int) "receive reports the real sender" 1 sender;
  Alcotest.(check string) "payload unchanged" "hello" payload
```

Match the file's existing functor/parameterization style for running the same test body against both `Sim_transport` and real `Tcp`.

- [ ] **Step 2: Run test to verify it fails**

Run: `dune build @all` — expected: FAIL to compile (`receive` still returns `string`, not `string * int`).

- [ ] **Step 3: Implement**

`Transport_intf.S.receive : t -> string * int`. `Sim_transport.receive` returns the already-known sender id verbatim (no behavior change beyond the tuple). `Tcp.receive`/`reader_body`/`handle_accepted`: decode the numeric replica id from the peer certificate's SAN actually presented and verified during the TLS handshake (the same SAN `lib/pki/ca.ml:164` already encodes) — not the handshake preamble's claimed id. Tag every payload pushed onto `t.inbox` with this authenticated id (the inbox's element type changes from `string` to `string * int`).

- [ ] **Step 4: Run test to verify it passes**

Run: `dune build @all && dune test --force` — expected: PASS, 428+1 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/transport/ lib/sim/sim_transport.ml lib/sim/sim_transport.mli test/test_transport_shared.ml
git commit -m "transport: receive returns the TLS-cert-authenticated sender id, not the unverified preamble claim"
```

### Task 2: `Tcp` rejects a second connection claiming an already-authenticated id

**Files:**
- Modify: `lib/transport/tcp.ml:159` (the `Hashtbl.replace` site), `tcp.mli`
- Test: `test/test_transport_tcp.ml`

**Interfaces:**
- Consumes: Task 1's authenticated-id decoding.

- [ ] **Step 1: Write the failing test**

```ocaml
let test_a_second_connection_claiming_an_already_connected_id_is_refused () =
  (* two real client connections, both authenticated (via their own certs) as id 1 against
     the same listener; the second connect must be refused, and the first connection's
     routing-table entry must be untouched *)
  Alcotest.(check bool) "second connection was refused" true (connect_attempt_2_failed);
  Alcotest.(check bool) "first connection can still send" true (send_via_first_still_works)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today's `Hashtbl.replace` silently evicts the first connection).

- [ ] **Step 3: Implement**

At the `Hashtbl.replace` call site (`tcp.ml:159`): if an entry for the authenticated id already exists and is live, close the new connection and raise/log a refusal instead of replacing the table entry.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/transport/tcp.ml lib/transport/tcp.mli test/test_transport_tcp.ml
git commit -m "transport: refuse a second connection claiming an id already authenticated, instead of silently replacing it"
```

### Task 3: `Prepare`/`Start_view` gain a real `source` field; `Replica.handle_message` cross-checks it against the transport-authenticated sender

**Files:**
- Modify: `lib/vsr/message.ml`, `message.mli` (add `source : int` to `Prepare`, `Start_view`)
- Modify: `lib/vsr/replica.ml:1813-1815`, `replica.mli` (`handle_message` signature)
- Modify: `lib/dst/cluster.ml` (the one real caller wiring transport to `Replica`)
- Test: `test/test_vsr_message.ml`, `test/test_vsr_replica.ml`, `test/test_dst_scenarios.ml`

**Interfaces:**
- Consumes: Task 1's `receive : t -> string * int`.
- Produces: `val handle_message : t -> sender:int -> string -> unit` (replaces `t -> string -> unit`).

- [ ] **Step 1: Write the failing test**

```ocaml
let test_handle_message_rejects_a_sender_mismatched_prepare () =
  (* build a well-formed Prepare whose payload claims source = 2, but call
     handle_message with ~sender:3 (simulating an authenticated connection from
     a different peer than the message claims) *)
  Alcotest.(check bool) "mismatched sender is rejected, total no-op"
    true (rejected_and_no_state_change)
```

Also add the old-format regression from Review Focus: a `Prepare`/`Start_view` encoded without `source` (pre-this-change shape) must fail decode loudly, not default `source` to some value.

```ocaml
let test_prepare_without_source_field_fails_decode_loudly () =
  Alcotest.check_raises "old-shaped Prepare is rejected, not silently accepted"
    (Malformed_message "...") (fun () -> ignore (Message.decode old_shaped_bytes))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL to compile / FAIL assertion.

- [ ] **Step 3: Implement**

Add `source : int` to `Prepare` and `Start_view` in the wire format (alongside the existing fields each already carries — mirror how `Prepare_ok`/`Do_view_change`/`Start_view_change` already carry `i`). `Replica.handle_message` takes `~sender:int`, and for every message-type branch, compares the payload's own claimed sender (`i` where present, the new `source` for `Prepare`/`Start_view`) against `~sender`; on mismatch, raise `Invalid_argument` before any state mutation (matching the existing "guard failure ⇒ total no-op, counted" convention `classify_append_refusal`-adjacent code already follows). Update `lib/dst/cluster.ml`'s dispatch loop to pass the sender it gets from `receive`.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune build @all && dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vsr/ lib/dst/cluster.ml test/test_vsr_message.ml test/test_vsr_replica.ml test/test_dst_scenarios.ml
git commit -m "vsr: Prepare/Start_view carry a real sender field; handle_message rejects a payload/transport sender mismatch"
```

### Task 4: `Tcp.send` validates against the real membership table

**Files:**
- Modify: `lib/transport/tcp.ml:514-522`, `tcp.mli`
- Test: `test/test_transport_tcp.ml`

**Interfaces:**
- Consumes: `t`'s existing membership table (already passed to `create`, per `tcp.mli:147`'s existing documented contract).

- [ ] **Step 1: Write the failing test**

```ocaml
let test_send_refuses_an_id_outside_the_configured_membership () =
  (* cluster membership = [0]; a connection is accepted that authenticates as id 99
     (Task 2 no longer applies here since 99 was never a member to begin with) *)
  Alcotest.check_raises "send to a non-member id is refused"
    (Invalid_argument "Tcp.send: no connection to peer 99")
    (fun () -> T.send t ~to_:99 "x")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today `send` succeeds once any connection claims id 99).

- [ ] **Step 3: Implement**

`send` checks `to_` against the membership table `create` was given before consulting the connection table; raise the existing `Invalid_argument "Tcp.send: no connection to peer <n>"` shape for both "never a member" and "member but no live connection" so the caller-visible behavior is unchanged for the already-tested case.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/transport/tcp.ml lib/transport/tcp.mli test/test_transport_tcp.ml
git commit -m "transport: Tcp.send refuses any id outside the membership table create was given"
```

---

## Group 2: Value/data-model codec hardening

### Task 5: Decode a `Map` key in place; drop the quadratic `String.sub` copy

**Files:**
- Modify: `lib/value.ml:238-240` (decode), the `Map` case of `encode_into` (`:89-94`)
- Test: `test/test_value.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_deeply_nested_map_keys_decode_in_linear_time () =
  let wire = build_nested_map_key_wire_bytes ~depth:20_000 in
  let start = Unix.gettimeofday () in
  ignore (Value.canonical_decode wire);
  let elapsed = Unix.gettimeofday () -. start in
  Alcotest.(check bool) "20k-deep nested map key decodes in well under 1s, not 1.6s+"
    true (elapsed < 1.0)
```

(Mirrors the audit's own depth-20,000 measurement, which took 1.64s and ~5.3GB peak under the current quadratic implementation — this pins the fix, not just the absence of a crash.)

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (elapsed ≥ 1.0, or the test times out under the suite's 15s watchdog).

- [ ] **Step 3: Implement**

Replace `read_bytes_exact`-then-recurse-into-the-copy with decoding the key directly against the outer buffer `s` at the current `pos`, passing the key blob's end offset (`pos + kblob_len`) as an expected-consumption bound to the recursive decode call, raising `Invalid_argument` if it doesn't consume exactly that many bytes. Apply the same in-place approach to `encode_into`'s `Map` case (currently allocates a fresh `Buffer` per nesting level).

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/value.ml test/test_value.ml
git commit -m "value: decode Map keys in place -- removes the quadratic copy-then-recurse that let a 742KB frame reach multi-GB memory"
```

### Task 6: `canonical_decode` enforces strict canonical ordering and rejects duplicates

**Files:**
- Modify: `lib/value.ml` (`Record`/`Map` decode arms; `canonical_encode`'s sort step)
- Test: `test/test_value.ml`

**Interfaces:**
- Consumes: Task 5's in-place `Map`-key decode (same code region).

- [ ] **Step 1: Write the failing test**

```ocaml
let test_decode_rejects_a_non_canonically_ordered_record () =
  let unsorted_wire = (* hand-built: Record{b=false; a=true}, keys out of order *) in
  Alcotest.check_raises "non-canonical field order is rejected on decode"
    (Invalid_argument "...") (fun () -> ignore (Value.canonical_decode unsorted_wire))

let test_decode_rejects_a_duplicate_key_record () =
  let dup_wire = (* hand-built: Record{k=true; k=false} *) in
  Alcotest.check_raises "duplicate keys are rejected on decode"
    (Invalid_argument "...") (fun () -> ignore (Value.canonical_decode dup_wire))

let test_canonical_encode_rejects_an_in_memory_duplicate_key () =
  let v = Value.Record [ ("k", Value.Scalar (Value.Bool true)); ("k", Value.Scalar (Value.Bool false)) ] in
  Alcotest.check_raises "duplicate keys are rejected on encode too"
    (Invalid_argument "...") (fun () -> ignore (Value.canonical_encode v))
```

Repeat the pair for `Map`.

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today both are silently accepted, per the audit's live reproduction).

- [ ] **Step 3: Implement**

In the `Record`/`Map` decode arms, track the previously-decoded key (field name for `Record`, raw key blob bytes for `Map`) and raise `Invalid_argument` if the next key is not strictly greater. In `canonical_encode`, after `List.stable_sort`, walk the sorted list once and raise `Invalid_argument` on any adjacent equal key.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/value.ml test/test_value.ml
git commit -m "value: canonical_decode rejects non-canonical ordering and duplicate keys; canonical_encode rejects duplicates too"
```

### Task 7: Find and fix any existing fixture relying on duplicate keys or non-canonical order

**Files:**
- Modify: any test fixture Task 6's new checks break (found via the build/test failure itself)

- [ ] **Step 1: Run the full suite to find breakage**

Run: `dune build @all && dune test --force` after Task 6 lands — this task exists specifically to catch and fix any fallout, per the spec's Migration note.

- [ ] **Step 2: Fix each broken fixture**

For each failure, either the fixture legitimately needs de-duplication (fix the fixture) or it was deliberately testing the old permissive behavior (retire the test with a commit message stating what compile/runtime failure now proves the old behavior is gone, matching this repo's existing retirement convention).

- [ ] **Step 3: Verify full suite green**

Run: `dune build @all && dune test --force` — expected: PASS, no other regressions.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "test: fix fixtures relying on duplicate-key or non-canonical wire ordering, now rejected by Task 6"
```

### Task 8: Bounded decode depth and an output-node budget

**Files:**
- Modify: `lib/value.ml` (`decode_value`, `encode_into` — thread a depth counter; `canonical_decode` — thread a node-count budget)
- Modify: `lib/value.mli` (document as real limits)
- Test: `test/test_value.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_decode_rejects_excessive_nesting_depth () =
  let wire = build_nested_sum_wire_bytes ~depth:2000 in
  Alcotest.check_raises "depth past 1000 is rejected cleanly, not left to the runtime stack"
    (Invalid_argument "...") (fun () -> ignore (Value.canonical_decode wire))

let test_decode_rejects_a_node_count_over_budget () =
  (* a 64 MiB-shaped frame declaring far more Sequence elements than the
     budget scaled to that size allows, at the cheapest possible per-element
     cost (Bool) -- mirrors the audit's own 33M-element/64MiB measurement *)
  Alcotest.check_raises "node budget is enforced before allocating them all"
    (Invalid_argument "...") (fun () -> ignore (Value.canonical_decode oversized_wire))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today both succeed, at real memory cost per the audit).

- [ ] **Step 3: Implement**

Thread an `int` depth parameter through `decode_value`/`encode_into`'s recursive calls, incrementing per `Record`/`Sum`/`Sequence`/`Map` level, raising `Invalid_argument` past 1000. Thread a mutable node-count ref through `canonical_decode`'s top-level entry, incrementing once per decoded node, raising once it exceeds a budget computed from the input's own byte length (calibrate the constant so the audit's own worst-case — a 64 MiB frame of all-`Bool` `Sequence` elements — is rejected well before it reaches gigabyte-scale live memory; document the exact formula in `value.mli`). Update `value.mli`'s "raises cleanly" language to state these are real, enforced bounds.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/value.ml lib/value.mli test/test_value.ml
git commit -m "value: bound decode depth and total node count -- closes the unbounded-recursion and memory-amplification findings"
```

### Task 9: Doc corrections — canonicality claim, envelope domain separation, dead reference

**Files:**
- Modify: `lib/value.mli:36-39`, `lib/envelope.ml:26-32`, `lib/envelope.mli:33-40`, `test/test_envelope.ml:67-79`, `test/test_value.ml:141-149`

- [ ] **Step 1: Edit each site**

`value.mli:36-39`: simplify the "need not be pre-sorted" claim (now unconditionally true post-Task 6, no caveat needed). `envelope.ml`/`envelope.mli`/`test_envelope.ml`: reword "can never collide, even under adversarial construction" to state the real, narrower property — collision is possible only for a payload of the literal shape `Sum ("Envelope", to_value e)`, an intentional, already-tested equivalence (`test_envelope.ml:88-94`), not a defect. `test_value.ml:141-149`: replace the dead `L4/final-review.md` reference with a pointer to `docs/superpowers/specs/2026-09-29-audit-remediation-design.md`.

- [ ] **Step 2: Verify the build and full suite still pass**

Run: `dune build @all && dune test --force` — expected: PASS (doc-only, no behavior change).

- [ ] **Step 3: Commit**

```bash
git add lib/value.mli lib/envelope.ml lib/envelope.mli test/test_envelope.ml test/test_value.ml
git commit -m "docs: correct value.mli's canonicality claim and envelope's overclaimed domain-separation wording; drop dead reference"
```

---

## Group 3: Storage layer hardening

### Task 10: Replace per-I/O `mmap` with a reusable aligned-buffer pool

**Files:**
- Modify: `lib/storage/file_storage.ml:141-151`, `lib/storage/file_kv_store.ml:106-116` (`alloc_aligned_buffer` and its call sites)
- Test: `test/test_file_storage.ml`, `test/test_file_kv_store.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_repeated_io_does_not_grow_the_process_map_count () =
  let before = count_self_maps () in
  for _ = 1 to 20_000 do (* append+read cycles against a real File_storage *) done;
  let after = count_self_maps () in
  Alcotest.(check bool) "map count stays flat, not linear in op count"
    true (after - before < 100)
```

(`count_self_maps` reads `/proc/self/maps` line count, matching the audit's own measurement method; mirrors the audit's own 20k-op run, which leaked ~80k VMAs under the current implementation.)

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (map count grows ~4 per op today).

- [ ] **Step 3: Implement**

Replace the per-call `Unix.map_file`-over-a-temp-file pattern with a small fixed-size pool of aligned buffers allocated once per `t` at `create`/`restart`, acquired before each I/O and explicitly released after (no reliance on GC finalization). Apply identically in `file_kv_store.ml`.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/file_storage.ml lib/storage/file_kv_store.ml test/test_file_storage.ml test/test_file_kv_store.ml
git commit -m "storage: replace per-I/O mmap with a reusable aligned-buffer pool -- closes the VMA-leak process crash"
```

### Task 11: A real filesystem-level lock on `create`

**Files:**
- Modify: `lib/storage/file_storage.ml` (`create`), `lib/storage/file_kv_store.ml` (`create`)
- Test: `test/test_file_storage.ml`, `test/test_file_kv_store.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_a_second_create_on_a_locked_directory_is_refused () =
  let _t1 = File_storage.create ~sw ~fs ~ring_capacity:16 dir in
  Alcotest.check_raises "a second create on the same directory is refused immediately"
    (Invalid_argument "...") (fun () -> ignore (File_storage.create ~sw ~fs ~ring_capacity:16 dir))
```

Repeat for `File_kv_store.create`.

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today both `create`s succeed and silently interleave).

- [ ] **Step 3: Implement**

Both `create`s take `Unix.lockf`/`flock(LOCK_EX | LOCK_NB)` on a `.riptide-lock` file in the target directory, held for the handle's lifetime (released on whatever this codebase's existing "close"/finalization path already is — follow the pattern the module already uses for its other owned fds). A second `create` against an already-locked directory raises `Invalid_argument` immediately.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/file_storage.ml lib/storage/file_kv_store.ml test/test_file_storage.ml test/test_file_kv_store.ml
git commit -m "storage: flock the target directory on create -- closes the two-processes-same-directory corruption finding"
```

### Task 12: Classify real I/O failures the same way guard-failures already are

**Files:**
- Modify: `lib/vsr/replica.ml` (`durable_append`, `classify_append_refusal`, `append_refusals` record/type)
- Modify: `lib/vsr/replica.mli`
- Test: `test/test_vsr_replica.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_a_real_io_failure_is_counted_as_storage_fault_not_left_unclassified () =
  (* a storage backend whose wal_append raises Eio.Io / Sys_error / Out_of_memory *)
  let result = Replica.propose faulty_replica value in
  Alcotest.(check bool) "propose returns cleanly (no escaped exception)" true (result_is_a_clean_refusal);
  Alcotest.(check int) "storage_fault bucket incremented"
    1 (Replica.append_refusals faulty_replica).storage_fault
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL to compile (`storage_fault` doesn't exist yet) then FAIL (exception escapes today).

- [ ] **Step 3: Implement**

Add a `storage_fault : int` field to the `append_refusals` record. `durable_append` adds a catch-all arm after the existing `Invalid_argument` match, recognizing `Eio.Io _ | Sys_error _ | Out_of_memory`, incrementing `storage_fault`, and returning `false` exactly as an ordinary refusal does.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vsr/replica.ml lib/vsr/replica.mli test/test_vsr_replica.ml
git commit -m "vsr: classify real I/O failures (Eio.Io/Sys_error/Out_of_memory) as a counted storage_fault refusal, not an unclassified escape"
```

### Task 13: A superblock-rebuild entry point

**Files:**
- Modify: `lib/storage/storage_intf.ml` (add `superblock_rebuild_from_wal`), `lib/storage/file_storage.ml`, `lib/storage/file_storage.mli`, `lib/storage/memory_storage.ml` (matching no-op/trivial implementation, since `Memory_storage` has no torn-write failure mode to begin with)
- Modify: `lib/vsr/replica.ml` (error message pointing at the new entry point)
- Test: `test/test_file_storage.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_superblock_rebuild_recovers_from_an_unreadable_superblock_over_an_intact_wal () =
  (* real File_storage, WAL populated, then all 3 superblock copies torn/destroyed
     out from under it so superblock_read returns None *)
  File_storage.superblock_rebuild_from_wal t;
  Alcotest.(check bool) "superblock_read now returns Some" true (Option.is_some (File_storage.superblock_read t))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL to compile (function doesn't exist).

- [ ] **Step 3: Implement**

`superblock_rebuild_from_wal : t -> unit`, callable only when `superblock_read t = None`, reconstructing a fresh superblock from `recover_highest_op_number`'s scan (the same recovery scan `create` already performs internally) and writing it via the existing `superblock_write`. `Replica.restart`'s error message on this state names this entry point.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/ lib/vsr/replica.ml test/test_file_storage.ml
git commit -m "storage: add superblock_rebuild_from_wal -- closes the permanent-softlock-with-a-recoverable-WAL finding"
```

### Task 14: Validate `ring_capacity >= 1` at `create`

**Files:**
- Modify: `lib/storage/file_storage.ml` (`create`)
- Test: `test/test_file_storage.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_create_rejects_a_non_positive_ring_capacity () =
  Alcotest.check_raises "ring_capacity <= 0 is rejected at create, not at first append"
    (Invalid_argument "ring_capacity must be >= 1")
    (fun () -> ignore (File_storage.create ~sw ~fs ~ring_capacity:0 dir))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today `create` succeeds, first append raises `Division_by_zero` or an `EINVAL`-shaped `Eio.Io`).

- [ ] **Step 3: Implement**

`create` raises `Invalid_argument "ring_capacity must be >= 1"` for `ring_capacity <= 0`, before any other work.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/file_storage.ml test/test_file_storage.ml
git commit -m "storage: validate ring_capacity >= 1 at create, instead of an unclassifiable exception on the first append"
```

### Task 15: Atomic owner-marker writes; a 0-byte marker is treated as unclaimed

**Files:**
- Modify: `lib/storage/file_kv_store.ml` (`check_or_write_owner_marker`)
- Test: `test/test_file_kv_store.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_a_zero_byte_marker_is_treated_as_unclaimed_not_as_owner_empty_string () =
  write_a_zero_byte_marker_directly dir;
  let t = File_kv_store.create ~sw ~fs ~owner:"redaction-store" dir in
  Alcotest.(check string) "the directory is now claimed by the real owner" "redaction-store" (File_kv_store.owner t)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today this raises `Invalid_argument "... is owned by \"\", not ..."` permanently, per the audit).

- [ ] **Step 3: Implement**

`check_or_write_owner_marker` moves from create-then-write (`Eio.Path.save ~create:(`Exclusive ...)`) to write-temp-then-rename, matching the durability pattern `durable_write` already uses elsewhere in this module. A marker read back as exactly 0 bytes is treated identically to a missing marker (write the real owner) rather than as a claimed empty-string owner.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/file_kv_store.ml test/test_file_kv_store.ml
git commit -m "storage: write the owner marker atomically; a 0-byte marker self-heals instead of permanently bricking the directory"
```

### Task 16: Randomize `File_kv_store`'s temp-file suffix per call

**Files:**
- Modify: `lib/storage/file_kv_store.ml:200-206` (`tmp_suffix`)
- Test: `test/test_file_kv_store.ml`

**Interfaces:**
- Consumes: nothing new. Produces the guarantee Task 20 (materializer lock) builds on for the in-process case, and is the sole fix for the cross-process case.

- [ ] **Step 1: Write the failing test**

```ocaml
let test_concurrent_same_key_puts_never_produce_a_torn_unreadable_record () =
  (* real concurrent Eio fibers, same key, distinguishable different-length values,
     driven the same way the audit's own reproduction did *)
  run_n_concurrent_puts_to_one_key ~n:16 ~key:"shared";
  let result = File_kv_store.get t ~key:"shared" in
  Alcotest.(check bool) "the surviving value is one writer's complete value, never a torn mix or None"
    true (is_one_of_the_written_values result)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (the audit measured ~3.9% phantom `None` and 36% raised exceptions today).

- [ ] **Step 3: Implement**

`tmp_suffix` becomes unique per call (e.g. `Printf.sprintf ".put.%d.%d.tmp" (Unix.getpid ()) (Atomic.fetch_and_add call_counter 1)`) instead of the fixed `".put.tmp"`, so concurrent same-key writers never share a temp path; POSIX `rename`'s atomicity then guarantees a reader always sees one complete writer's record.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/file_kv_store.ml test/test_file_kv_store.ml
git commit -m "storage: randomize File_kv_store's temp-file suffix per call -- closes the torn-write/phantom-None finding"
```

### Task 17: Temp files live in the target directory, not `TMPDIR`

**Files:**
- Modify: `lib/storage/file_storage.ml` (`alloc_aligned_buffer`, post-Task-10 shape), `lib/storage/file_kv_store.ml` (put-path temp-file creation)
- Test: `test/test_file_storage.ml`, `test/test_file_kv_store.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_storage_operations_do_not_depend_on_tmpdir () =
  Unix.putenv "TMPDIR" "/nonexistent-audit-check-dir";
  let t = File_storage.create ~sw ~fs ~ring_capacity:16 dir in
  File_storage.wal_append t ~op_number:1 "x";
  Alcotest.(check bool) "append succeeded without a usable TMPDIR" true true
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (`Sys_error` from `Filename.temp_file` today, per the audit's live reproduction).

- [ ] **Step 3: Implement**

Move both modules' temp-file creation into the target storage directory itself (already required to be the same filesystem as the final destination, for `rename` to be atomic — this fix removes a latent cross-filesystem atomicity risk as a side effect of removing the `TMPDIR` dependency).

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/file_storage.ml lib/storage/file_kv_store.ml test/test_file_storage.ml test/test_file_kv_store.ml
git commit -m "storage: create temp files in the target directory instead of TMPDIR -- removes a hard TMPDIR dependency and a latent atomicity risk"
```

### Task 18: `File_kv_store` shards its flat directory

**Files:**
- Modify: `lib/storage/file_kv_store.ml` (`path_for`), `file_kv_store.mli` (document the remaining space/inode cost ceiling)
- Test: `test/test_file_kv_store.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_path_for_shards_across_subdirectories () =
  let p1 = path_for_test_hook dir ~key:"a" and p2 = path_for_test_hook dir ~key:"totally-different-key" in
  Alcotest.(check bool) "two keys with different hash prefixes land in different subdirectories"
    true (Filename.dirname p1 <> Filename.dirname p2)
```

Plus a round-trip test: `put`/`get`/`delete` still work correctly through the new sharded path.

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today `path_for` produces one flat directory).

- [ ] **Step 3: Implement**

`path_for` inserts a two-level directory prefix from the first 2 and next 2 hex characters of `hash_to_hex (content_hash key)` before the filename (matching common content-addressed-store convention). `create`/`put` ensure the intermediate directories exist (`mkdir -p`-shaped). Document the remaining ~123× space amplification and one-inode-per-key cost explicitly in `file_kv_store.mli` as a supported key-count range note.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/file_kv_store.ml lib/storage/file_kv_store.mli test/test_file_kv_store.ml
git commit -m "storage: shard File_kv_store's flat directory by hash prefix; document the remaining space/inode cost ceiling"
```

### Task 19: Minor bundle — O_DIRECT misdetection, use-after-close, startup-cost doc

**Files:**
- Modify: `lib/storage/file_storage.ml` (`perform_write`/`perform_read`'s `with Eio.Io _ when h.direct_capable`, `downgrade_to_dsync_only`), `lib/storage/file_kv_store.ml` (same patterns), `file_storage.mli` (startup-cost doc note)
- Test: `test/test_file_storage.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_an_unrelated_write_error_does_not_permanently_strip_o_direct () =
  (* a transient, non-O_DIRECT-related write error (e.g. simulated EFBIG via
     a small RLIMIT_FSIZE), then confirm the fd's O_DIRECT flag survives *)
  Alcotest.(check bool) "O_DIRECT is still set after an unrelated transient error"
    true (is_o_direct_still_set ())

let test_a_failed_reopen_during_downgrade_does_not_use_a_closed_fd () =
  (* force the reopen inside downgrade_to_dsync_only to fail (e.g. EMFILE) and
     confirm h.direct_capable is already false, so no later operation retries
     the closed fd *)
  Alcotest.(check bool) "direct_capable is false before the reopen is attempted"
    true (direct_capable_set_before_reopen_attempt)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL against the current blanket-catch/order-of-operations bugs.

- [ ] **Step 3: Implement**

Narrow `with Eio.Io _ when h.direct_capable` to the specific errno shapes that actually indicate O_DIRECT-unsupported (not every `Eio.Io`). In `downgrade_to_dsync_only`, set `h.direct_capable <- false` before attempting the reopen, not after it succeeds. Add a doc note to `file_storage.mli` next to the existing `ring_capacity` sizing guidance, quantifying the real O(`ring_capacity`) `create`/`recover_highest_op_number` startup cost (~53 µs/slot per the audit's measurement).

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/ test/test_file_storage.ml
git commit -m "storage: narrow the O_DIRECT-unsupported catch to real errno shapes; fix use-after-close on a failed reopen; document startup cost"
```

---

## Group 4: Materializer concurrency + divergence fixes

### Task 20: Per-`merge_key` serialization inside `Materializer`

**Files:**
- Modify: `lib/materialize/materializer.ml`, `materializer.mli`
- Test: `test/test_materializer.ml`

**Interfaces:**
- Consumes: Task 16's randomized temp suffix (no more torn writes at the KV layer).

- [ ] **Step 1: Write the failing test**

```ocaml
let test_concurrent_writers_to_one_merge_key_lose_no_updates () =
  (* n real concurrent Eio fibers, distinguishable elements, same merge_key,
     mirroring the audit's own G-set reproduction *)
  run_n_concurrent_writes ~n:16 ~merge_key:"shared";
  let result = Materializer.read t ~merge_key:"shared" in
  Alcotest.(check int) "all 16 elements present, not just 1" 16 (Set.cardinal result)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (the audit measured exactly 1 survivor at n=16, deterministically).

- [ ] **Step 3: Implement**

Add a hashtable of `Eio.Mutex.t` (or the codebase's existing equivalent primitive) keyed by `merge_key`, created lazily on first use, held around `Materializer.write`'s read-join-put for that key.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/materialize/ test/test_materializer.ml
git commit -m "materialize: serialize concurrent writers per merge_key -- closes the deterministic lost-update finding"
```

### Task 21: Per-write materialization failure no longer aborts the whole batch or replay

**Files:**
- Modify: `lib/batch_commit/batch_commit.ml` (`propose`'s write loop, `materialize_up_to`'s replay loop), `batch_commit.mli`
- Test: `test/test_batch_commit_materialize.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_one_oversized_write_in_a_batch_does_not_block_sibling_materialization () =
  (* a batch with one write that overflows the 4096-byte cap and one unrelated
     merge_key well under it *)
  ignore (propose_batch_expecting_the_overflow_exception ());
  let sibling = Materializer.read t ~merge_key:"sibling" in
  Alcotest.(check bool) "the sibling key materialized despite the other write's overflow"
    true (sibling <> L.bottom)

let test_restart_replay_does_not_permanently_stop_after_one_poisoned_key () =
  (* commit past a poisoning write, restart, re-materialize from the log;
     a LATER key committed after the poison must still materialize *)
  let fresh = materialize_up_to fresh_replica ~through_commit_number in
  Alcotest.(check bool) "a later, unrelated key materialized despite the earlier poison"
    true (Materializer.read fresh ~merge_key:"late" <> L.bottom)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (both loops today abort entirely on the first raising write, per the audit's live reproduction).

- [ ] **Step 3: Implement**

Extract (or add, if none exists) one shared per-write materialize-and-catch helper used by both `propose`'s write loop and `materialize_up_to`'s replay loop: catch a raising `Materializer.write`, count it (reusing Task 12's `storage_fault`-adjacent counting convention where it fits, or a dedicated counter if the two don't share a natural type), and continue to the next write rather than aborting the loop. Update `batch_commit.mli`'s doc: the accumulator is "a function of the committed log plus each key's own size-bound history," not "the committed log alone."

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/batch_commit/ test/test_batch_commit_materialize.ml
git commit -m "batch_commit: a poisoned write no longer aborts materialization of every write after it, live or on restart replay"
```

### Task 22: A useful error message names the `merge_key`

**Files:**
- Modify: `lib/materialize/materializer.ml` (the overflow `Invalid_argument` message)
- Test: `test/test_materializer.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_overflow_error_names_the_merge_key () =
  Alcotest.check_raises "the error message includes the merge_key, not just byte counts"
    (Invalid_argument (Printf.sprintf "put: merge_key %S -- value of ... exceeds ..." "the-key"))
    (fun () -> overflow_a_key ~merge_key:"the-key")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today's message omits the key entirely).

- [ ] **Step 3: Implement**

Include `merge_key` in the `Invalid_argument` message `Materializer.write` raises on overflow.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/materialize/materializer.ml test/test_materializer.ml
git commit -m "materialize: overflow error names the merge_key, making the one existing failure signal actionable"
```

### Task 23: Promote `Lattice_conformance` to an installable library

**Files:**
- Create: `lib/lattice_conformance/lattice_conformance.ml`, `lib/lattice_conformance/dune`
- Modify: `test/lattice_conformance.ml` (becomes a thin consumer, or is removed if the moved module covers everything), `test/dune`

- [ ] **Step 1: Move the module**

Move `test/lattice_conformance.ml`'s property-based law-checking harness into `lib/lattice_conformance/lattice_conformance.ml` as a real library (matching this codebase's one-library-per-concern convention). Update `test/dune`'s existing lattice-conformance tests to depend on the new library instead of the old test-local module.

- [ ] **Step 2: Verify the existing conformance tests still pass unchanged**

Run: `dune build @all && dune test --force` — expected: PASS, same tests, now sourced from the library.

- [ ] **Step 3: Commit**

```bash
git add lib/lattice_conformance/ test/lattice_conformance.ml test/dune
git commit -m "lattice: promote Lattice_conformance to an installable library, so a caller's own lattice can actually be conformance-checked"
```

---

## Group 5: Crypto/redaction policy

### Task 24: `Kv_store_intf.S` gains `fold`; `Redaction_store` stores `event_id` alongside each wrapped record

**Files:**
- Modify: `lib/storage/kv_store_intf.ml` (add `val fold`), `lib/storage/file_kv_store.ml`/`.mli` (real implementation via directory listing, post-Task-18 sharded layout)
- Modify: `lib/crypto/redaction_store.ml`/`.mli` (store `event_id` alongside the wrapped bytes)
- Test: `test/test_file_kv_store.ml`, `test/test_redaction.ml`

**Interfaces:**
- Produces: `val fold : t -> init:'a -> (key:string -> 'a -> 'a) -> 'a`, consumed by Task 25.

- [ ] **Step 1: Write the failing test**

```ocaml
let test_fold_visits_every_key_currently_present () =
  List.iter (fun k -> File_kv_store.put t ~key:k "v") ["a"; "b"; "c"];
  let seen = File_kv_store.fold t ~init:[] ~f:(fun ~key acc -> key :: acc) in
  Alcotest.(check (list string)) "all three keys visited" ["a"; "b"; "c"] (List.sort compare seen)

let test_redaction_store_records_survive_a_round_trip_with_their_event_id_recoverable () =
  Redaction_store.wrap t ~event_id:"evt-1" plaintext_dek;
  (* fold + decode must recover "evt-1" without it being supplied externally *)
  let found = List.exists (fun id -> id = "evt-1") (enumerate_event_ids t) in
  Alcotest.(check bool) "event_id is recoverable via enumeration alone" true found
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL to compile (`fold` doesn't exist yet).

- [ ] **Step 3: Implement**

`File_kv_store.fold` walks the (now-sharded, per Task 18) directory tree, decoding each valid record's key back from its stored form (or, if the key itself isn't recoverable from the hashed filename alone, `fold`'s contract is documented precisely as visiting each stored record without claiming to recover a key the store never kept in the clear — check `File_kv_store`'s actual stored-key semantics before writing this contract, and write `kv_store_intf.mli`'s doc to match exactly what's true). `Redaction_store.wrap` (or wherever the wrapped-DEK record is written) additionally stores the plaintext `event_id` alongside the wrapped bytes in the same record (it is not secret — it is already the caller-supplied AAD `Kek.unwrap` requires).

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/kv_store_intf.ml lib/storage/file_kv_store.ml lib/storage/file_kv_store.mli lib/crypto/redaction_store.ml lib/crypto/redaction_store.mli test/test_file_kv_store.ml test/test_redaction.ml
git commit -m "storage,crypto: add Kv_store_intf.S.fold; Redaction_store records now carry their own event_id -- enumeration no longer needs an external log replay"
```

### Task 25: `Redaction_store.rotate_kek`

**Files:**
- Modify: `lib/crypto/redaction_store.ml`/`.mli`
- Test: `test/test_redaction.ml`

**Interfaces:**
- Consumes: Task 24's `fold` and stored `event_id`.
- Produces: `val rotate_kek : t -> new_kek:Kek.t -> unit`.

- [ ] **Step 1: Write the failing test**

```ocaml
let test_rotate_kek_re_wraps_every_entry_and_old_kek_no_longer_decrypts () =
  List.iter (fun id -> Redaction_store.wrap t ~event_id:id dek) ["e1"; "e2"; "e3"];
  Redaction_store.rotate_kek t ~new_kek:kek2;
  Alcotest.(check bool) "every entry still decrypts, now under kek2"
    true (List.for_all (fun id -> Redaction_store.decrypt_with t ~kek:kek2 ~event_id:id <> None) ["e1"; "e2"; "e3"]);
  Alcotest.(check bool) "the old kek no longer works"
    true (List.for_all (fun id -> Redaction_store.decrypt_with t ~kek:kek1 ~event_id:id = None) ["e1"; "e2"; "e3"])

let test_rotate_kek_interrupted_partway_leaves_a_readable_mix_not_torn_entries () =
  (* simulate a fault after 2 of 3 entries have rotated; both the 2 rotated
     entries (under new_kek) and the 1 not-yet-rotated (under old_kek) must
     each independently decrypt cleanly under their respective key -- no
     entry is individually torn *)
  Alcotest.(check bool) "no entry is torn; each is fully old-keyed or fully new-keyed"
    true (every_entry_is_wholly_one_kek_or_the_other)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL to compile (`rotate_kek` doesn't exist).

- [ ] **Step 3: Implement**

`rotate_kek` folds over the keystore (Task 24's `fold`), and for each entry: reads the stored `event_id`, unwraps under `t`'s current KEK, re-wraps under `new_kek`, writes back via the store's existing atomic write path (Task 15/Task 16's write-temp-then-rename, already per-entry-atomic). `redaction_store.mli` documents this as the KEK-compromise remediation path.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/crypto/redaction_store.ml lib/crypto/redaction_store.mli test/test_redaction.ml
git commit -m "crypto: add Redaction_store.rotate_kek -- the first KEK-compromise remediation path that doesn't require destroying all data"
```

### Task 26: Retract the keystore-backup recommendation; pin the real guarantee with a test

**Files:**
- Modify: `lib/crypto/redaction_store.mli` (the backup recommendation paragraph)
- Test: `test/test_redaction.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_a_pre_redaction_keystore_backup_defeats_redaction () =
  Redaction_store.wrap t ~event_id:"evt-1" dek;
  let backup = snapshot_the_keystore_directory dir in
  Redaction_store.redact t ~event_id:"evt-1";
  Alcotest.(check bool) "live store: genuinely gone" true (Redaction_store.decrypt t ~event_id:"evt-1" ciphertext = None);
  Alcotest.(check bool) "a pre-redaction backup + the KEK still recovers it -- the real, disclosed guarantee"
    true (decrypt_from_backup backup ~event_id:"evt-1" ciphertext <> None)
```

(This test's assertions confirm the *documented* limitation, not a bug — it fails to compile/run only if the backup+KEK path has been accidentally broken by something else in this plan; its purpose is to pin the honest disclosure with running code, per `CLAUDE.md`'s "no spec without running code" rule.)

- [ ] **Step 2: Run test to verify it passes as written**

Run: `dune test --force` — expected: PASS immediately (this is a disclosure-pinning test, not a bug-fix test — no code change makes it fail first).

- [ ] **Step 3: Edit `redaction_store.mli`**

Remove the recommendation to back up the keystore directory "with the same care the KEK file gets." Replace with the precise guarantee: redaction deletes the live keystore's only pointer to a record's wrapped DEK; it has no effect on any copy of that pointer made before the redaction. State that durability instead comes from this system's own replication (a wrapped DEK already lives on every replica via ordinary VSR commit) and that `redact` must be applied to every replica's keystore to be effective cluster-wide. State plainly that any backup/retention policy for keystore-derived data must independently prune redacted entries, or must not exist past the shortest tolerable redaction-latency window.

- [ ] **Step 4: Verify the full suite passes**

Run: `dune build @all && dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/crypto/redaction_store.mli test/test_redaction.ml
git commit -m "crypto: retract the keystore-backup recommendation that silently defeated redaction; pin the real guarantee with a running test"
```

### Task 27: `require_encryption` becomes a construction-time policy on `Batch_commit`

**Files:**
- Modify: `lib/batch_commit/batch_commit.ml`/`.mli` (constructor gains `?require_encryption`, `propose` keeps its own override)
- Test: `test/test_batch_commit.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_handle_level_require_encryption_catches_a_call_site_that_forgot_it () =
  let t = Batch_commit.create ~require_encryption:true (* ... *) in
  Alcotest.check_raises "a propose call with no ~encryption is refused by the handle's own policy"
    (Invalid_argument "...") (fun () -> propose_without_encryption t)

let test_per_call_override_still_works () =
  let t = Batch_commit.create ~require_encryption:true (* ... *) in
  ignore (propose_without_encryption ~require_encryption:false t) (* does not raise *)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL to compile (`create` has no such parameter yet).

- [ ] **Step 3: Implement**

`Batch_commit.create` gains `?require_encryption:bool` (default `false`, unchanged default behavior), stored on the handle. `propose`'s existing `?require_encryption` parameter, when supplied, overrides the handle's default for that one call; when omitted, the handle's stored policy applies.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/batch_commit/batch_commit.ml lib/batch_commit/batch_commit.mli test/test_batch_commit.ml
git commit -m "batch_commit: require_encryption moves to a construction-time handle policy, so one forgotten call site can't silently skip it"
```

---

## Group 6: Transport resource limits

### Task 28: A configurable cap on concurrent accepted connections

**Files:**
- Modify: `lib/transport/tcp.ml` (`create`, accept loop), `tcp.mli`
- Test: `test/test_transport_tcp.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_connections_beyond_the_cap_are_refused_before_any_handshake () =
  let t = Tcp.create ~max_connections:8 (* ... *) in
  let accepted = attempt_n_connections t ~n:20 in
  Alcotest.(check bool) "at most 8 concurrently accepted, the rest refused pre-handshake"
    true (accepted <= 8)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today unbounded, per the audit's 315-connection listener-death reproduction).

- [ ] **Step 3: Implement**

`Tcp.create` gains `?max_connections:int` (default scaled to the membership table's size — generous enough for normal reconnect churn, far below any realistic fd ulimit). The accept loop refuses (closes immediately, no handshake attempted) any connection beyond the cap.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/transport/tcp.ml lib/transport/tcp.mli test/test_transport_tcp.ml
git commit -m "transport: cap concurrent accepted connections -- closes the unauthenticated fd-exhaustion listener-death finding"
```

### Task 29: `EMFILE` on `accept` is not counted toward the fatal error budget

**Files:**
- Modify: `lib/transport/tcp.ml:62-63` and the accept loop's error handling
- Test: `test/test_transport_tcp.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_emfile_does_not_kill_the_listener () =
  (* simulate EMFILE on accept accept_max_consecutive_errors+5 times in a row *)
  Alcotest.(check bool) "the listener process/fiber is still alive and accepting after recovery"
    true (listener_still_alive)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today it re-raises fatally past the threshold, per the audit's live reproduction).

- [ ] **Step 3: Implement**

Exclude `EMFILE` specifically from `accept_max_consecutive_errors`'s counter; on `EMFILE`, log and back off briefly (a short sleep) before retrying `accept`, rather than counting toward the fatal threshold.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/transport/tcp.ml test/test_transport_tcp.ml
git commit -m "transport: EMFILE on accept backs off and retries instead of eventually killing the listener process"
```

### Task 30: A bounded inbox and a read-idle timeout on established connections

**Files:**
- Modify: `lib/transport/tcp.ml:457` (`Eio.Stream.create max_int`), `run_connection`/`reader_body` (idle timeout)
- Test: `test/test_transport_tcp.ml`

**Interfaces:**
- Consumes: Task 1's `(payload, sender)`-shaped inbox (this task bounds its capacity; the element shape is unaffected).

- [ ] **Step 1: Write the failing test**

```ocaml
let test_inbox_capacity_is_bounded_not_unbounded () =
  (* a sender that keeps sending while the receiver never calls receive;
     memory must plateau, not grow without bound, mirroring the audit's
     own 20,000 x 64KiB reproduction *)
  Alcotest.(check bool) "RSS growth stays bounded" true (rss_growth_is_bounded)

let test_a_connection_silent_after_the_preamble_is_eventually_closed () =
  (* complete a real handshake + preamble, then send zero further bytes for
     longer than the new idle timeout *)
  Alcotest.(check bool) "the connection is closed after the idle timeout, not held forever"
    true (connection_was_closed_after_idle_timeout)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today's inbox is unbounded and there is no post-preamble timeout, per the audit).

- [ ] **Step 3: Implement**

`Eio.Stream.create max_int` becomes a finite, configurable capacity (a full inbox blocks the sending fiber — real backpressure). `run_connection`/`reader_body` gain a read-idle timeout, reusing the same mechanism the existing 10s handshake/preamble timeouts already use, closing a connection that goes silent past the threshold after its handshake completes.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/transport/tcp.ml test/test_transport_tcp.ml
git commit -m "transport: bound the inbox capacity and add a post-preamble read-idle timeout -- closes unbounded memory growth and unbounded fd holding"
```

---

## Group 7: Consensus operability

### Task 31: Ring-wedge early warning, `?may_evict` actually wired, and a documented resize-before-wedge procedure

**Files:**
- Modify: `lib/storage/storage_intf.ml` (add `ring_margin`), `lib/storage/file_storage.ml`/`.mli`
- Modify: `lib/dst/cluster.ml` (wire `?may_evict` through the real `File_storage.create` call site) and any other production-shaped caller found by grep
- Test: `test/test_file_storage.ml`, `test/test_dst_scenarios.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_ring_margin_reports_real_remaining_capacity () =
  let t = File_storage.create ~sw ~fs ~ring_capacity:16 dir in
  append_n_ops t ~n:10;
  Alcotest.(check int) "6 slots of margin remain" 6 (File_storage.ring_margin t)

let test_eviction_blocked_actually_increments_when_may_evict_is_wired () =
  (* a real cluster.ml-shaped File_storage.create with ?may_evict wired,
     driven past ring_capacity *)
  Alcotest.(check bool) "eviction_blocked > 0, not structurally pinned at 0"
    true (Replica.append_refusals t).eviction_blocked > 0

let test_a_ring_can_be_resized_before_it_wedges_by_copying_live_entries () =
  (* the documented, tested resize procedure: copy every still-live entry
     from a near-full small-capacity File_storage into a fresh
     larger-capacity one, before the wedge occurs *)
  Alcotest.(check bool) "the new, larger store holds every entry the old one had"
    true (new_store_holds_all_entries)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (`ring_margin` doesn't exist; `eviction_blocked` is structurally pinned at 0 per the audit; no resize procedure exists or is tested).

- [ ] **Step 3: Implement**

`ring_margin : t -> int` returns `ring_capacity` minus the count of not-yet-evicted entries. Thread `?may_evict` through `lib/dst/cluster.ml`'s `File_storage.create` call (and any other real caller found by `grep -rn "File_storage.create" lib/ test/`) so `eviction_blocked` actually increments as `replica.mli` already documents. Write the resize test as a real procedure — create a fresh, larger-capacity `File_storage`, read every live entry from the old one (via existing `wal_read`), write it to the new one — and document this as the supported resize-before-wedge runbook in `file_storage.mli`.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/ lib/dst/cluster.ml test/test_file_storage.ml test/test_dst_scenarios.ml
git commit -m "storage,dst: expose ring_margin, wire may_evict through the real production call site, document+test a resize-before-wedge procedure"
```

### Task 32: A stranded replica keeps retrying its view-change broadcast

**Files:**
- Modify: `lib/vsr/replica.ml` (`try_forfeit_view_change`, `check_timeout`, `svc_count` increment site)
- Test: `test/test_dst_scenarios.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_a_dropped_start_view_change_broadcast_is_retried_not_abandoned () =
  (* mirrors the audit's own 3d reproduction: one SVC broadcast dropped
     during a transient partition, then the partition heals *)
  drive_n_more_timeouts_after_the_drop ~n:5;
  Alcotest.(check bool) "the replica rejoins the cluster once the partition heals"
    true (replica_status_is_normal_again)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today, R2 never heals in this exact scenario, per the audit's live reproduction).

- [ ] **Step 3: Implement**

`try_forfeit_view_change`/`check_timeout`: while below quorum, re-broadcast `StartViewChange` on each subsequent timeout (bounded by the existing `svc_limit`), instead of going silent after the first attempt. Fix `svc_count` not incrementing on the below-quorum path in the same change, so the retry budget is accurate.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vsr/replica.ml test/test_dst_scenarios.ml
git commit -m "vsr: a below-quorum replica keeps retrying its StartViewChange broadcast instead of silently stranding itself forever"
```

### Task 33: Content-check the committed prefix on `Start_view`/`truncate_wal`

**Files:**
- Modify: `lib/vsr/replica.ml`/`.mli` (`truncate_wal`, `handle_start_view` guards)
- Test: `test/test_vsr_replica.ml`, `test/test_vsr_replica_view_change.ml`

- [ ] **Step 1: Write the failing test**

```ocaml
let test_start_view_refuses_a_committed_prefix_content_mismatch () =
  (* a Start_view whose log's first commit_number entries differ in content
     from what's already locally committed, same length *)
  Alcotest.check_raises "a content-mismatched committed prefix is refused wholesale"
    (Invalid_argument "...") (fun () -> Replica.handle_message t ~sender:1 forged_start_view_bytes)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL (today the content check doesn't exist, only a length check).

- [ ] **Step 3: Implement**

`truncate_wal`/`handle_start_view`: additionally compare the incoming log's entries covering `[1, local commit_number]` against the locally held committed entries' content hashes; refuse wholesale (same "stop, don't destroy" convention as the existing C1 `restart` finding) on any mismatch. This is inert for every correct execution (`NoLogDivergence` already holds for all honest traffic) and, combined with Group 1's sender authentication, is real defense in depth rather than the sole safety mechanism.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune test --force` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vsr/replica.ml lib/vsr/replica.mli test/test_vsr_replica.ml test/test_vsr_replica_view_change.ml
git commit -m "vsr: content-check the committed prefix on Start_view/truncate_wal, not just its length"
```

### Task 34: Observability event hook, `peer_op_number`/`svc_count` exposure, doc corrections

**Files:**
- Modify: `lib/vsr/replica.ml`/`.mli` (`?on_event`; `peer_op_number` accessor; `svc_count` accessor)
- Modify: `docs/superpowers/specs/2026-09-24-layer0-followup-hardening-design.md` (correct the stale claim)
- Test: `test/test_vsr_replica.ml`

**Interfaces:**
- Consumes: Task 3/12's classified refusal shapes (surfaced through the new hook), Task 32's now-accurate `svc_count`.

- [ ] **Step 1: Write the failing test**

```ocaml
let test_on_event_reports_a_commit_number_decrease () =
  let events = ref [] in
  let t = Replica.create ~on_event:(fun e -> events := e :: !events) (* ... *) in
  (* drive a scenario where commit_number genuinely decreases, per the
     documented view-change-lowers-commit case *)
  Alcotest.(check bool) "a Commit_decreased event was emitted" true (List.exists is_commit_decreased !events)

let test_peer_op_number_is_a_real_accessor () =
  Alcotest.(check bool) "peer_op_number is reachable outside tests" true (ignore (Replica.peer_op_number t ~peer:2); true)

let test_svc_count_is_a_real_accessor () =
  Alcotest.(check bool) "svc_count is reachable outside tests, matching what replica.mli:538 already claims"
    true (ignore (Replica.svc_count t); true)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dune test --force` — expected: FAIL to compile (none of the three exist yet; `on_commit_advanced` filters decreases out per `replica.mli:465`).

- [ ] **Step 3: Implement**

Add `?on_event:(replica_event -> unit)` to `Replica.create`/`restart`, mirroring `?on_commit_advanced`'s existing shape, with `replica_event` a closed variant covering guard rejections (Task 3/12's classified refusals), status transitions, and `commit_number` decreases specifically (not filtered, unlike the existing hook). Add real `peer_op_number : t -> peer:int -> int option` and `svc_count : t -> int` accessors. In `docs/superpowers/specs/2026-09-24-layer0-followup-hardening-design.md`, correct the still-present claim about disk-full triggering "a loud, distinguishable exception" (never shipped) to point forward to Task 12's `storage_fault` classification instead.

- [ ] **Step 4: Run test to verify it passes**

Run: `dune build @all && dune test --force` — expected: PASS, full suite green.

- [ ] **Step 5: Commit**

```bash
git add lib/vsr/replica.ml lib/vsr/replica.mli docs/superpowers/specs/2026-09-24-layer0-followup-hardening-design.md test/test_vsr_replica.ml
git commit -m "vsr: add ?on_event, peer_op_number, svc_count; correct a stale spec claim about unshipped disk-full behavior"
```

---

## Final step: whole-branch review and finishing

After Task 34, this plan's executor (per `subagent-driven-development`) dispatches the final whole-branch code review, fixes every finding regardless of severity (standing operator preference — no deferred Minors), confirms `dune build @all && dune test --force` is green, and then follows `superpowers:finishing-a-development-branch` — which, per this box's own norms, means presenting the merge/push decision explicitly rather than pushing to `main` autonomously.
