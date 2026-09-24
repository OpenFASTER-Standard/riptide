# Layer 0 Follow-Up Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close six real, disclosed gaps (task-master subtasks 3.6, 3.7, 3.8, 4.5, 4.6, 4.7) found
by this session's own adversarial reviews: VSR wire integrity, a general multi-replica
ring-eviction watermark, a deployment-required-encryption policy, exclusive keystore/materializer
directory ownership, a deterministic fix for a flaky DST test, and PKI certificate/key persistence.

**Architecture:** Eight tasks. 3.8 goes first (a stable, non-flaky test suite is worth having under
every later task's own new tests). 3.6, 4.5, 4.6, 4.7 are each one self-contained addition to an
existing module and can be done in any order after that. 3.7 (the biggest, most novel item) is
split into three tasks — trigger hook, gate primitive, then integration + proof — and goes last so
it lands on top of a suite already free of the 3.8 flake.

**Tech Stack:** OCaml 5, Eio, `x509`/`mirage-crypto`, this repo's own `Riptide_vsr`/`Riptide_storage`/
`Riptide_batch_commit`/`Riptide_pki`/`Riptide_sim`/`Riptide_dst` libraries.

**Spec:** `docs/superpowers/specs/2026-09-24-layer0-followup-hardening-design.md`

## Global Constraints

- 3.6's checksum defends against accidental corruption only (this is a crash-fault-tolerant
  protocol, not Byzantine) — not a cryptographic MAC, not a security boundary.
- 3.6 reuses `lib/vsr/message.ml`'s existing `Malformed_message` exception; it does not introduce a
  new exception type.
- 3.7's trigger hook on `Riptide_vsr.Replica` takes only integers (`old_commit`/`new_commit`) —
  `Replica` must stay domain-agnostic and never learn about materialization, redaction, or
  `Value.value`.
- 3.7's gate predicate lives on `Riptide_storage.File_storage`; a write whose `merge_key` was never
  set remains exactly as vulnerable to eviction as it was before this whole materialization effort
  — an existing, unchanged, disclosed boundary.
- 4.5's `?require_encryption` defaults to `false`, matching every other opt-in flag `Batch_commit`
  already has (`?materialize`, `?encryption`).
- 4.6's `?owner` on `File_kv_store.create` is optional, for backward compatibility with every
  existing caller/test that doesn't pass it.
- 4.7's `Ca` private-key persistence reuses `Kek.load`'s exact permission-check discipline: checked
  via `Unix.fstat` on the already-open file descriptor (never `Unix.stat` on the path — that has a
  TOCTOU gap `Kek.load` already closes), rejecting any mode with `0o077` (group/other access) set.
- Every task ships with real, running, tested code in the same change that introduces any rule it
  establishes, per this repo's `CLAUDE.md` "no spec without running code" rule.

## Review Focus

- **A corrupted VSR message must be dropped, not crash the replica.** `Riptide_vsr.Replica.handle_message`
  already catches `Message.Malformed_message` at `lib/vsr/replica.ml:1733` and drops the message
  silently (`-> ()`) — Task 2's checksum must raise through that exact same path, not a new one a
  reasonable person would expect to already be covered but isn't. (3.6)
- **A write with no `merge_key` must be completely unaffected by the new eviction gate.** A
  reasonable person reading this feature's name ("ring-eviction watermark") would assume it only
  ever adds new protection, never new blocking — a write that never opted into materialization
  hitting the new gate anyway would be a real regression on an existing, disclosed boundary. (3.7)
- **`require_encryption:true` combined with an existing `merge_key`+`encryption` rejection must
  still raise for the pre-existing reason, not a new, confusing one.** `Batch_commit.propose`
  already raises `Invalid_argument` when a write's `merge_key` is set alongside `~encryption`
  (from the just-merged plan's Task 6) — a caller combining that with `~require_encryption:true`
  should see one clear failure, not two competing ones. (4.5)
- **`File_kv_store.create`'s new `?owner` check must never break a caller that doesn't use it.**
  Every existing test and caller omits `~owner` — a reasonable person upgrading this library
  should see zero behavior change until they opt in, not a new required argument or a construction
  failure on old code. (4.6)
- **The dst_scenarios determinism fix must not silently gut the fault-injection test it's fixing.**
  A reasonable person reading "fixed the flake" would assume the corruption/drop scenario is still
  genuinely exercised — a fix that happens to eliminate the flake by making faults never actually
  fire would pass CI while silently deleting the thing the test exists to prove. (3.8)

---

### Task 1: Deterministic dst_scenarios fix (subtask 3.8)

**Files:**
- Modify: `lib/sim/network.ml`, `lib/sim/network.mli`
- Test: `test/test_dst_scenarios.ml` (existing tests must still pass; add a soak-test proving the fix)

**Interfaces:**
- Consumes: nothing from later tasks.
- Produces: nothing later tasks depend on — this is a standalone reliability fix.

**Root cause, already confirmed by direct code reading (not fixed here, described so the fix is
grounded, not guessed):** `Riptide_sim.Network.send` (`lib/sim/network.ml:69-83`) draws every fault
decision (`drop`/`duplicate`/`corrupt`) from one shared `Prng.t` **at send time**, consumed in
whatever order `send` calls actually happen. `lib/dst/cluster.ml`'s `settle()` uses a real
`Eio.Time.sleep clock 0.0001` as its `wait_io` (`cluster.ml:331`) specifically because real
`File_storage` I/O genuinely needs real wall-clock time to complete via io_uring — this sleep is
*correct* and must not be removed or replaced with a fake tick count (there is no way to make
genuine disk I/O completion deterministic without mocking the I/O layer itself, which would defeat
the point of testing against real `File_storage`). What actually varies run-to-run is *which
replica's fiber resumes first* after a real I/O completion, which changes the *order* `Network.send`
gets called in across replicas, which — because the fault PRNG is a single shared, order-consumed
stream — changes which message gets flagged for corruption/drop.

**The fix:** make each fault decision depend on something that does **not** vary with real I/O
completion order: a per-sender, monotonically-increasing send counter. Each replica's *own*
internal sequence of things it decides to send is deterministic given the protocol's logic (a
replica doesn't consult another replica's real I/O timing to decide what message N of its own
sends looks like) — it's only the *interleaving* across replicas that varies. Keying the fault
decision off `(sender_id, that sender's own Nth send)` instead of "whichever PRNG draw comes next
globally" removes the interleaving-order dependency entirely.

- [ ] **Step 1: Write the failing (flaky) reproduction, quantified**

Before touching any code, quantify the current flake rate so the fix has a real before/after. Run:

```bash
for i in $(seq 1 40); do
  dune exec test/test_riptide.exe -- test dst_scenarios 5 2>&1 | tail -3
done | grep -c FAIL
```

Expected: a small but nonzero count (the investigation that found this saw 2/40). Record the exact
count you get — this is your baseline.

- [ ] **Step 2: Implement per-sender-keyed fault decisions**

Read the real, current `lib/sim/network.ml` and `lib/sim/network.mli` in full before editing —
this plan does not restate the whole file. The type `'msg t` (`network.ml`) currently holds one
shared `prng : Prng.t`. Add a per-sender counter table and a per-message deterministic sub-PRNG:

```ocaml
(* In the type definition, alongside the existing prng field: *)
send_counts : (peer_id, int) Hashtbl.t;

(* In create: *)
send_counts = Hashtbl.create 16;

(* Replace the shared-prng fault draws in `send` with a per-(sender, count)-derived one: *)
let fault_prng_for net ~from_ =
  let count = Option.value (Hashtbl.find_opt net.send_counts from_) ~default:0 in
  Hashtbl.replace net.send_counts from_ (count + 1);
  (* Derive a fresh, deterministic sub-seed from the base seed, the sender id, and this
     sender's own send count -- NOT from net.prng's shared, order-dependent stream. *)
  Prng.create (Hashtbl.hash (Prng.int net.prng max_int, from_, count))
```

Wait — `Prng.int net.prng max_int` still consumes the shared stream in call order, reintroducing
the exact problem. Do not do that. Instead derive the sub-seed purely from data already fixed at
`Network.create` time (the base seed) plus `(from_, count)`, with no further draw from the shared
`prng` inside `send` for the fault-decision purpose:

```ocaml
(* In the type definition: *)
base_seed : int;
send_counts : (peer_id, int) Hashtbl.t;

(* In create ~faults prng () -- Prng.t doesn't expose its own seed, so thread the base seed
   through create's own argument list instead of trying to recover it from prng: *)
val create : faults:fault_config -> seed:int -> unit -> 'msg t

let create ~faults ~seed () =
  { faults; prng = Prng.create seed; base_seed = seed; send_counts = Hashtbl.create 16;
    (* ...existing fields... *) }

let fault_prng_for net ~from_ =
  let count = Option.value (Hashtbl.find_opt net.send_counts from_) ~default:0 in
  Hashtbl.replace net.send_counts from_ (count + 1);
  Prng.create (Hashtbl.hash (net.base_seed, from_, count))
```

This changes `Network.create`'s signature (it gains `~seed`, replacing whatever currently
constructs the internal `prng` from a caller-supplied `Prng.t`) — check every real call site
(`lib/dst/cluster.ml` and any test file constructing a `Network.t` directly) before finalizing the
exact shape; adapt call sites to pass the same seed value they already use to build their own
`Prng.t` today, so behavior for `min_delay`/`max_delay`-driven delivery timing (which can stay on
the original shared `net.prng`, since delivery *timing* jitter isn't the thing causing the flake —
only the fault-type decision is) is otherwise unchanged.

In `send` (`network.ml:69-83`), replace `Prng.bool net.prng net.faults.drop_probability` /
`net.faults.duplicate_probability` / `net.faults.corrupt_probability` with
`Prng.bool (fault_prng_for net ~from_) ...` for each of the three decisions (using three
independent sub-draws from that one per-message `fault_prng_for` result, or three separately-keyed
sub-PRNGs if that reads cleaner against the real code — verify against the real `send` function's
exact current structure).

- [ ] **Step 3: Update `network.mli`'s own documentation**

The module's top comment currently states: "the same seed always produces the same sequence of
drop/duplicate/corrupt decisions and delays, called in the same order." Correct this to state the
truth post-fix: fault decisions are now keyed per-sender, independent of cross-replica delivery
interleaving, so the same seed produces the same fault decision for "the Nth message a given
replica sends," regardless of real I/O timing — not a single global sequence "in the same order"
(which was never true under real, non-mocked I/O to begin with, which is the whole reason this task
exists).

- [ ] **Step 4: Re-run the quantified reproduction from Step 1**

```bash
for i in $(seq 1 40); do
  dune exec test/test_riptide.exe -- test dst_scenarios 5 2>&1 | tail -3
done | grep -c FAIL
```

Expected: `0`. If not zero, the per-sender keying alone didn't fully close the gap — investigate
whether some other shared-PRNG consumption (e.g. delivery delay jitter) is still order-dependent in
a way that affects which corrupted message lands where, before concluding the fix is complete.

**Review Focus: confirm the fix didn't silently gut the fault injector's own power** (a
determinism fix that happened to make faults stop firing at all would also make the flake
disappear, for the wrong reason). Before moving on, run test index 5 once with `-v` and inspect its
own printed evidence (its header comment, quoted in this plan's Task 2 Context section, documents
the exact command:
`dune exec test/test_riptide.exe -- test dst_scenarios 5 -v`) — confirm it still reports a nonzero
count of genuinely corrupted deliveries (the test's own `is_clean`/`erased` accounting, unchanged
by this task), proving `corrupt_probability` is still doing real work post-fix, not just that the
specific flake stopped reproducing.

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `dune clean && dune build && dune test --force`, at least 3 times.
Expected: identical pass count every time, matching the pre-Task-1 baseline exactly (no new
failures, no new flakiness introduced elsewhere by the `Network.create` signature change).

- [ ] **Step 6: Commit**

```bash
git add lib/sim/network.ml lib/sim/network.mli
git commit -m "sim: key fault-injection decisions per-sender, not per-global-send-order -- fixes dst_scenarios' ring-capacity-boundary flake"
```

---

### Task 2: VSR wire integrity checksum (subtask 3.6)

**Files:**
- Modify: `lib/vsr/message.ml`, `lib/vsr/message.mli`
- Modify: `test/test_dst_scenarios.ml` (flip the existing pinned-failing-by-design corruption test
  into a positive assertion)
- Test: `test/test_vsr_message.ml` (extend)

**Interfaces:**
- Consumes: nothing from other tasks in this plan.
- Produces: nothing later tasks depend on.

**Context, already confirmed by direct code reading:**
- `lib/vsr/message.ml:74`: `let encode (t : t) : string = Value.canonical_encode (to_value t)`.
- `lib/vsr/message.ml:160-162`: `let decode (s : string) : t = let v = try Value.canonical_decode s with Invalid_argument msg -> raise (Malformed_message msg) in of_value v`.
- `lib/vsr/message.ml:21`: `exception Malformed_message of string` — already defined, reused, not replaced.
- `lib/vsr/replica.ml:1732-1733`: `match Message.decode bytes with | exception Message.Malformed_message _ -> ()` — `handle_message` **already** silently drops any decode failure. Adding a checksum-verification failure that raises `Malformed_message` requires **zero changes to `replica.ml`** — this is the single biggest simplification this task benefits from; do not add any new handling there.
- `test/test_dst_scenarios.ml:676-830` (`test_wire_corruption_diverges_committed_state`, the DST
  scenario's test index 5 as of this plan's writing — confirm the current index against the real
  file before editing, since Task 1 doesn't change test count but earlier or later tasks in this
  plan might): a real, extensively-commented, deliberately-pinned-failing-by-design test proving
  the *current* broken behavior (a corrupted wire byte destroys a committed value cluster-wide).
  Its own header comment explicitly names this exact checksum approach as "the task report's top
  recommendation" and says "if it ever starts passing without a divergence, something real changed
  and this test should be turned into the positive assertion" — this task is that change.

- [ ] **Step 1: Write the failing test for the checksum itself**

`test/test_vsr_message.ml` — read the real, current file first for its existing style/helpers, then
add:

```ocaml
let test_decode_rejects_a_corrupted_encoding () =
  let msg = Message.Prepare { view = 1; n = 1; v = Riptide.Value.Scalar (Riptide.Value.String "x"); k = 0 } in
  let encoded = Message.encode msg in
  (* Flip one byte roughly in the middle of the encoding -- avoids the length-prefix bytes at
     the very start most canonical encodings carry, so this is a real content-corruption test,
     not a length-field corruption test (a different failure mode). *)
  let corrupted = Bytes.of_string encoded in
  let mid = Bytes.length corrupted / 2 in
  Bytes.set corrupted mid (Char.chr (Char.code (Bytes.get corrupted mid) lxor 0xFF));
  let corrupted = Bytes.to_string corrupted in
  Alcotest.check_raises "a corrupted encoding is rejected as malformed" (Message.Malformed_message "placeholder")
    (fun () -> ignore (Message.decode corrupted))
```

`Alcotest.check_raises` compares exception *shape*, not payload equality for exceptions carrying a
string — verify against this project's own established pattern for testing exceptions-with-payload
(see how other tests in this repo already assert on `Malformed_message`/`Invalid_argument` with a
real message, e.g. `test/test_dek.ml` or `test/test_redaction.ml`'s own conventions) and adjust to
whichever real, working form this codebase already uses — the exact assertion mechanics are a real
detail to verify against real, currently-passing test code, not guessed.

Also add a positive round-trip test confirming a *clean* (uncorrupted) message still encodes and
decodes correctly after this change — the checksum must never break the happy path:

```ocaml
let test_encode_decode_roundtrips_with_the_new_checksum () =
  let msg = Message.Prepare_ok { view = 2; n = 5; i = 1 } in
  Alcotest.(check bool) "a clean encoding still decodes to the same message" true
    (Message.decode (Message.encode msg) = msg)
```

- [ ] **Step 2: Run to verify failure**

Run: `dune build && dune exec test/test_riptide.exe -- test vsr_message`
Expected: `test_decode_rejects_a_corrupted_encoding` fails (the corrupted bytes currently decode
successfully into a different, well-formed message rather than raising).

- [ ] **Step 3: Implement the checksum**

`lib/vsr/message.ml`:

```ocaml
(* Accidental-corruption detection only, not a security boundary: VSR is a crash-fault-tolerant
   protocol (not Byzantine), and the network-corruption case this originally guarded against is
   already closed for every real deployment by Riptide_transport.Tcp's own mandatory mutual TLS
   (AES-GCM authenticated encryption fails closed on a tampered record before VSR ever sees the
   bytes). What this catches instead: corruption introduced somewhere other than the network --
   a local encoding bug, or bytes that were already corrupted before retransmission. 8 bytes
   (64 bits) is far more collision resistance than this threat model needs. *)
let checksum_length = 8

let checksum body =
  let full = Digestif.SHA256.digest_string body |> Digestif.SHA256.to_raw_string in
  String.sub full 0 checksum_length

let encode (t : t) : string =
  let body = Value.canonical_encode (to_value t) in
  body ^ checksum body

let decode (s : string) : t =
  let total_len = String.length s in
  if total_len < checksum_length then
    raise (Malformed_message (Printf.sprintf "message too short to carry a checksum (%d bytes)" total_len));
  let body_len = total_len - checksum_length in
  let body = String.sub s 0 body_len in
  let claimed = String.sub s body_len checksum_length in
  if not (String.equal claimed (checksum body)) then
    raise (Malformed_message "checksum mismatch -- message corrupted in transit or at rest");
  let v = try Value.canonical_decode body with Invalid_argument msg -> raise (Malformed_message msg) in
  of_value v
```

Verify `Digestif.SHA256` is the exact, real module this codebase already uses for hashing
elsewhere (check `lib/value.ml`'s own `content_hash` implementation, since this project's existing
convention should be reused rather than a second hashing approach introduced) — adjust the exact
module/function names to match if this codebase's real hashing call looks different (e.g. it may
already wrap `Digestif` behind `Riptide.Value`'s own hash helper, in which case reuse that instead
of calling `Digestif` directly from `message.ml`).

`lib/vsr/message.mli` — update the module's own top comment (quoted in this plan's Task 2 Files
section reasoning above) to document the new trailing checksum as part of the wire format,
explicitly noting it is accidental-corruption detection, not authentication, and that
`Message.Malformed_message` is `Replica.handle_message`'s own existing, unchanged silent-drop
signal.

- [ ] **Step 4: Run to verify pass**

Run: `dune build && dune exec test/test_riptide.exe -- test vsr_message`
Expected: both new tests `[OK]`.

- [ ] **Step 5: Flip the existing DST corruption test from pinned-failing to a positive assertion**

Read `test/test_dst_scenarios.ml`'s real, current `test_wire_corruption_diverges_committed_state`
(the whole function and its extensive header comment, quoted in this plan's Context section above)
in full before editing. Update:

- The header comment: remove the "NOT FIXED HERE, deliberately" framing and the "if it ever starts
  passing without a divergence... this test should be turned into the positive assertion"
  instruction — replace with a comment stating this checksum fix is exactly that change, dated and
  cross-referenced to this task.
- The two `Alcotest.(check bool)` assertions at the end (currently checking `divergences <> []` and
  `erased <> []`, i.e. asserting the bug's presence): flip to `divergences = []` and `erased = []`
  — a corrupted `Prepare` should now be silently dropped by the receiving replica (matching every
  other malformed/dropped message this harness already handles gracefully via VSR's own
  retry/timeout machinery), never accepted as a legitimately different committed value.
- Rename the test function if its current name (`test_wire_corruption_diverges_committed_state`)
  no longer describes the post-fix behavior — e.g.
  `test_wire_corruption_is_detected_and_dropped_not_accepted`.

- [ ] **Step 6: Run to verify the flipped test passes, and run the whole DST suite repeatedly**

Run: `dune clean && dune build && dune test --force`, at least 3 times.
Expected: the renamed/flipped test passes every time; no other test regresses.

- [ ] **Step 7: Commit**

```bash
git add lib/vsr/message.ml lib/vsr/message.mli test/test_vsr_message.ml test/test_dst_scenarios.ml
git commit -m "vsr: add a wire-integrity checksum to Message.encode/decode, closing subtask 3.6 -- corrupted messages are now dropped, not silently accepted"
```

---

### Task 3: Deployment-required encryption policy (subtask 4.5)

**Files:**
- Modify: `lib/batch_commit/batch_commit.ml`, `lib/batch_commit/batch_commit.mli`
- Modify: `lib/log.mli` (documentation only)
- Test: `test/test_batch_commit.ml` (extend)

**Interfaces:**
- Consumes: nothing from other tasks in this plan.
- Produces: nothing later tasks depend on.

**Context, already confirmed by direct code reading:** `lib/batch_commit/batch_commit.ml:172`:
`let propose (t : Riptide_vsr.Replica.t) ~(idempotency_key : string) ?(materialize : materialize_sink option) ...` —
read the real, current full signature (it also takes `?encryption`, confirmed to exist from the
just-merged plan's own Task 6) before editing. `Log.append` (`lib/log.mli:1-8`) is confirmed, via
repo-wide `grep`, to have zero callers outside `lib/log.ml` and its own tests — it is not a
production write path.

- [ ] **Step 1: Write the failing test**

`test/test_batch_commit.ml` — read the real, current file's helpers first (it should already have
a `w`-style write-construction helper and a way to build a solo replica, matching the conventions
every prior task in the just-merged plan already used), then add:

```ocaml
let test_require_encryption_rejects_a_plaintext_propose () =
  let replica = (* build a solo replica using this file's existing real helper *) in
  Alcotest.check_raises "require_encryption:true with no ~encryption sink raises"
    (Invalid_argument "propose: require_encryption is true but no ~encryption sink was supplied")
    (fun () ->
      Batch_commit.propose replica ~idempotency_key:"k1" ~require_encryption:true
        [ w "hello" ] (* using this file's existing write-construction helper *))

let test_require_encryption_true_with_a_real_sink_succeeds () =
  let replica = (* solo replica *) in
  let sink = (* a real encryption_sink, using this file's or test_redaction.ml's existing
                pattern for constructing one against a real Redaction_store *) in
  Batch_commit.propose replica ~idempotency_key:"k2" ~require_encryption:true ~encryption:sink
    [ w "hello" ];
  Alcotest.(check int) "the batch committed" 1 (List.length (Batch_commit.committed_envelopes replica))

let test_require_encryption_true_still_raises_for_the_pre_existing_merge_key_reason () =
  (* Review Focus: require_encryption must not mask or confuse the pre-existing merge_key +
     ~encryption rejection (from the just-merged plan's own Task 6) -- one clear failure, not
     two competing ones. Here require_encryption's own check can't even fire yet (~encryption
     IS supplied), so the ORIGINAL merge_key rejection must still be the one that raises. *)
  let replica = (* solo replica *) in
  let sink = (* a real encryption_sink, as above *) in
  Alcotest.check_raises "merge_key + encryption is still rejected, unchanged by require_encryption"
    (Invalid_argument "propose: a write with merge_key cannot also carry ~encryption")
    (* exact message copied from the real, current merge_key+encryption check -- verify against
       lib/batch_commit/batch_commit.ml's real, current Invalid_argument text before finalizing;
       this is a placeholder for that exact string, not a guess to leave unverified. *)
    (fun () ->
      Batch_commit.propose replica ~idempotency_key:"k3" ~require_encryption:true ~encryption:sink
        [ { (w "hello") with merge_key = Some "mk" } ])
```

Read `test/test_redaction.ml`'s real, current helpers for constructing a genuine `encryption_sink`
against a real `Redaction_store` before writing these tests — reuse that pattern rather than
inventing a new one. Before finalizing `test_require_encryption_true_still_raises_for_the_pre_existing_merge_key_reason`,
read the real, current `merge_key`+`encryption` rejection in `batch_commit.ml` (added by the
just-merged plan's Task 6) and copy its exact `Invalid_argument` message verbatim — do not guess
the string.

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i require_encryption`
Expected: compile failure — `require_encryption` is not a recognized labelled argument to `propose`
yet.

- [ ] **Step 3: Implement `?require_encryption`**

Read the real, current `propose` function body in full (`lib/batch_commit/batch_commit.ml`,
starting at line 172) before editing — this plan does not restate its existing control flow. Add
the new optional argument and, as the very first check inside the function (before the existing
`merge_key`+`encryption` rejection, so a caller sees the more fundamental policy violation first if
both are somehow triggered by the same call):

```ocaml
let propose (t : Riptide_vsr.Replica.t) ~(idempotency_key : string)
    ?(require_encryption = false) ?(materialize : materialize_sink option) ?(encryption : encryption_sink option) writes =
  if require_encryption && encryption = None then
    invalid_arg "propose: require_encryption is true but no ~encryption sink was supplied";
  (* ...rest of the existing, real function body, unchanged... *)
```

Verify the exact real parameter order/existing checks against the current file — this sketch shows
the new check's *position* (first) and *content*, not a full transcription of the unchanged
remainder.

`lib/batch_commit/batch_commit.mli` — document `?require_encryption` on `propose`'s own doc
comment: what it does, that it defaults to `false`, and that a real deployment choosing to run
encrypted should always pass `true` from its own calling code (matching the module's own
established "policy lives at the call site, not inside this mechanism" framing already used for
`?materialize`/`?encryption`).

`lib/log.mli` — add one paragraph to the module's existing top comment stating plainly: this is a
pre-VSR-consensus prototype module, superseded by `Batch_commit`+`Riptide_vsr.Replica` for real
replicated writes; confirmed via repo-wide `grep` to have no production callers as of this
writing; not a production write path, and therefore intentionally NOT covered by `?require_encryption`
or any of `Batch_commit`'s other opt-in capabilities.

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force`
Expected: both new tests `[OK]`, full suite otherwise unchanged.

- [ ] **Step 5: Commit**

```bash
git add lib/batch_commit/batch_commit.ml lib/batch_commit/batch_commit.mli lib/log.mli test/test_batch_commit.ml
git commit -m "batch_commit: add ?require_encryption, a real deployment-level policy primitive -- closes subtask 4.5"
```

---

### Task 4: Exclusive keystore/materializer directory ownership (subtask 4.6)

**Files:**
- Modify: `lib/storage/file_kv_store.ml`, `lib/storage/file_kv_store.mli`
- Modify: `lib/crypto/redaction_store.ml`, `lib/crypto/redaction_store.mli`
- Modify: `lib/materialize/materializer.mli` (doc only — `Materializer.create` takes a `KV.t`
  already constructed by the caller, so the owner tag is supplied at `File_kv_store.create` time,
  not at `Materializer.create` time; verify this against the real code before assuming it)
- Test: `test/test_file_kv_store.ml` (extend), `test/test_lattice_materialize_crypto_scenarios.ml`
  (update the existing pinned collision-reproduction test)

**Interfaces:**
- Consumes: `Riptide_storage.File_kv_store.create : sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> string -> t` (real, current signature, confirmed).
- Produces: `File_kv_store.create` gains `?owner:string`, consumed by `Redaction_store`/anyone else
  constructing a `File_kv_store.t`.

**Context, already confirmed by direct code reading:** `Kv_store_intf.S` (`lib/storage/kv_store_intf.ml`)
is `get`/`put`/`delete` only — no notion of ownership at that abstraction level, which is correct;
this task adds ownership enforcement to the concrete `File_kv_store` implementation, not the
interface, since ownership is about *this backend's* shared-directory failure mode specifically.

- [ ] **Step 1: Write the failing test**

`test/test_file_kv_store.ml` — read the real, current file's helpers first, then add:

```ocaml
let test_owner_mismatch_is_rejected_at_construction () =
  Eio_main.run @@ fun env ->
  let dir = Filename.temp_file "riptide_kv_owner_test" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let (_ : File_kv_store.t) = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore" dir in
      Alcotest.check_raises "a second, different owner is rejected"
        (Invalid_argument (Printf.sprintf "File_kv_store.create: %s is owned by \"redaction-keystore\", not \"materializer\"" dir))
        (fun () -> ignore (File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" dir)))

let test_matching_owner_reopens_cleanly () =
  Eio_main.run @@ fun env ->
  let dir = Filename.temp_file "riptide_kv_owner_test2" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let t1 = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore" dir in
      File_kv_store.put t1 ~key:"k" "v";
      let t2 = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore" dir in
      Alcotest.(check (option string)) "the same-owner reopen sees the same data" (Some "v")
        (File_kv_store.get t2 ~key:"k"))

let test_no_owner_supplied_is_unaffected () =
  (* Backward compatibility: every existing test/caller that omits ~owner must see zero
     behavior change -- this test just re-runs an existing, simple put/get round trip with
     no ~owner argument at all, confirming create still works exactly as before. *)
  Eio_main.run @@ fun env ->
  let dir = Filename.temp_file "riptide_kv_no_owner_test" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      File_kv_store.put t ~key:"k" "v";
      Alcotest.(check (option string)) "put/get with no owner tag still works" (Some "v")
        (File_kv_store.get t ~key:"k"))
```

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i owner`
Expected: compile failure — `~owner` is not a recognized labelled argument to `File_kv_store.create`
yet.

- [ ] **Step 3: Implement `?owner`**

Read the real, current `File_kv_store.create` implementation in full before editing (this plan does
not restate its existing directory-open/create logic). Add an owner-marker check using the same
"try the operation, catch `Eio.Io`" discipline this module's own top comment already documents for
every other existence check (since, per that same documented fact, this installed Eio's `Path` has
no `kind`/`stat` existence check to use instead):

```ocaml
let owner_marker_name = ".riptide-kv-owner"

let check_or_write_owner_marker ~fs ~dir_path owner =
  match owner with
  | None -> ()
  | Some tag ->
    let marker_path = Eio.Path.(fs / dir_path / owner_marker_name) in
    (match Eio.Path.load marker_path with
     | existing ->
       if not (String.equal existing tag) then
         invalid_arg
           (Printf.sprintf "File_kv_store.create: %s is owned by %S, not %S" dir_path existing tag)
     | exception Eio.Io _ ->
       (* No marker yet -- this is the first owner to claim this directory. *)
       Eio.Path.save ~create:(`Exclusive 0o600) marker_path tag)

let create ~sw ~fs ?owner dir_path =
  (* ...existing directory-open/create logic, unchanged... *)
  check_or_write_owner_marker ~fs ~dir_path owner;
  (* ...rest of existing create, unchanged... *)
```

Verify `Eio.Path.load`/`Eio.Path.save` are the real, correct functions for this (confirm against
the installed Eio 0.12 `path.mli`, and against how this same file's own existing code already reads
small marker-shaped files, if it does anything similar already) — and verify the exact point in
`create`'s real control flow where the directory is guaranteed to already exist (the marker check
must run after the directory itself is created/opened, not before).

`lib/storage/file_kv_store.mli` — document `?owner` on `create`'s own doc comment: what it protects
against (the just-merged plan's own confirmed keystore/materializer collision finding), that it's
optional for backward compatibility, and that omitting it on both sides of a real collision leaves
the hazard exactly as unprotected as before this task (a caller opting out is not this task's
responsibility to save from itself).

`lib/crypto/redaction_store.ml`/`.mli` — update `Redaction_store.create`'s own construction path
(wherever it builds or receives its `File_kv_store.t`) to require/pass a real, fixed owner tag —
read the real, current file to find exactly where its `File_kv_store.create` call (or the point
where its caller is expected to construct one) lives, and use a tag like `"redaction-keystore"`.

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force`
Expected: all three new tests `[OK]`, full suite otherwise unchanged.

- [ ] **Step 5: Update the existing pinned collision-reproduction test**

Read `test/test_lattice_materialize_crypto_scenarios.ml`'s real, current collision test (added by
the just-merged plan's Task 9 fix round — search for its real current name, likely something like
`sharing one KV directory between a keystore and a materializer silently destroys a wrapped DEK`)
in full before editing. Update it to construct both the `Redaction_store`'s `File_kv_store` and the
`Materializer`'s `File_kv_store` with **different** owner tags pointed at the **same** directory,
and assert `File_kv_store.create`'s second call now raises `Invalid_argument` — replacing its
current assertions (which prove the three silent-corruption outcomes) with one proving construction
now fails loudly before either consumer can touch the shared directory at all. Keep a comment
explaining why this is a strictly stronger guarantee than what the test proved before.

- [ ] **Step 6: Run to verify the whole suite is green**

Run: `dune clean && dune build && dune test --force`, at least 2 times.

- [ ] **Step 7: Commit**

```bash
git add lib/storage/file_kv_store.ml lib/storage/file_kv_store.mli lib/crypto/redaction_store.ml lib/crypto/redaction_store.mli test/test_file_kv_store.ml test/test_lattice_materialize_crypto_scenarios.ml
git commit -m "storage: File_kv_store.create gains ?owner, closing subtask 4.6 -- a keystore/materializer directory collision now fails loudly at construction"
```

---

### Task 5: PKI certificate/key persistence (subtask 4.7)

**Files:**
- Modify: `lib/pki/ca.ml`, `lib/pki/ca.mli`
- Test: `test/test_pki.ml` (extend)

**Interfaces:**
- Consumes: `X509.Private_key.encode_pem : X509.Private_key.t -> string`,
  `X509.Private_key.decode_pem : string -> (X509.Private_key.t, [> \`Msg of string]) result`,
  `X509.Certificate.encode_pem : X509.Certificate.t -> string`,
  `X509.Certificate.decode_pem : string -> (X509.Certificate.t, [> \`Msg of string]) result` — all
  four confirmed real and installed (`x509` 1.2.0, `/work/toolchain/opam-root/5.0.0/lib/x509/x509.mli`
  lines 160-649).
- Produces: `Ca.save : t -> dir:string -> unit`, `Ca.load : dir:string -> t`, consumed by whoever
  eventually needs a persistent CA (no current caller in this repo — library capability only, per
  the spec's own confirmed scope).

**Context, already confirmed by direct code reading:** `lib/pki/ca.mli:41`: `type t = { key : X509.Private_key.t; cert : X509.Certificate.t }` — a plain exposed record. `lib/crypto/kek.ml:26-33`'s
`check_permissions` is the exact permission-check pattern to mirror (`Unix.fstat` on the open
descriptor, rejecting any `0o077` bit).

- [ ] **Step 1: Write the failing test**

`test/test_pki.ml` — read the real, current file's helpers first, then add:

```ocaml
let test_save_load_roundtrips_and_the_loaded_ca_still_signs_valid_leaves () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  let dir = Filename.temp_file "riptide_ca_persist_test" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Ca.save ca ~dir;
      let loaded = Ca.load ~dir in
      let leaf_cert, _leaf_key = Ca.sign_leaf loaded ~common_name:"replica-1" ~valid_days:365 in
      let time = Ptime_clock.now () in
      match
        X509.Validation.verify_chain_of_trust ~host:None ~time:(fun () -> Some time)
          ~anchors:[ ca.Ca.cert ] [ leaf_cert ]
      with
      | Ok _ -> ()
      | Error e -> Alcotest.fail (Fmt.to_to_string X509.Validation.pp_validation_error e))

let test_load_on_a_world_readable_key_file_is_rejected () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  let dir = Filename.temp_file "riptide_ca_perm_test" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Ca.save ca ~dir;
      (* Widen the saved private-key file's permissions after the fact, the same live-attack
         shape Kek.load's own permission test already uses. *)
      Sys.command (Printf.sprintf "chmod 644 %s/ca-key.pem" (Filename.quote dir)) |> ignore;
      Alcotest.check_raises "a world-readable CA key file is rejected on load"
        (Invalid_argument (Printf.sprintf "Ca.load: %s/ca-key.pem has mode 0644, which grants access to group or other; a CA private key file must be 0600 or stricter" dir))
        (fun () -> ignore (Ca.load ~dir)))
```

Confirm the real, exact `verify_chain_of_trust`/`pp_validation_error` call shape against
`test_pki.ml`'s own already-existing, real (verified by the just-merged plan's own Task 7) usage
rather than the sketch above, which mirrors it from memory — the real file is the source of truth.
Confirm this environment (this box runs as root per prior sessions' own findings) doesn't bypass
the permission test the way it bypassed an equivalent one for `File_kv_store`'s own delete-path
testing — if it does, the second test may need adjustment or an explicit skip/documentation of why,
matching how that earlier, analogous situation was handled.

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i "Ca\.\(save\|load\)"`
Expected: compile failure — `Ca.save`/`Ca.load` don't exist yet.

- [ ] **Step 3: Implement `Ca.save`/`Ca.load`**

`lib/pki/ca.ml` — add, near the existing `generate_root`/`sign_leaf`:

```ocaml
let cert_filename = "ca-cert.pem"
let key_filename = "ca-key.pem"

let save t ~dir =
  let cert_path = Filename.concat dir cert_filename in
  let oc = open_out_bin cert_path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc (X509.Certificate.encode_pem t.cert));
  let key_path = Filename.concat dir key_filename in
  (* 0o600 at creation time, matching Kek's own file-permission discipline for private key
     material -- created restrictively from the start, not permissioned down after the fact. *)
  let fd = Unix.openfile key_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let oc = Unix.out_channel_of_descr fd in
  Fun.protect ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc (X509.Private_key.encode_pem t.key))

(* Mirrors Kek.check_permissions (lib/crypto/kek.ml:26-33) exactly: checked via the already-open
   descriptor, not the path, so nothing can swap the file between the check and the read. *)
let check_key_permissions ~path fd =
  let st = Unix.fstat fd in
  if st.Unix.st_perm land 0o077 <> 0 then
    invalid_arg
      (Printf.sprintf "Ca.load: %s has mode %04o, which grants access to group or other; a CA private key file must be 0600 or stricter"
         path st.Unix.st_perm)

let load ~dir =
  let cert_path = Filename.concat dir cert_filename in
  let ic = open_in_bin cert_path in
  let cert_pem =
    Fun.protect ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  in
  let cert =
    match X509.Certificate.decode_pem cert_pem with
    | Ok cert -> cert
    | Error (`Msg m) -> failwith (Printf.sprintf "Ca.load: %s: %s" cert_path m)
  in
  let key_path = Filename.concat dir key_filename in
  let ic = open_in_bin key_path in
  let key_pem =
    Fun.protect ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        check_key_permissions ~path:key_path (Unix.descr_of_in_channel ic);
        really_input_string ic (in_channel_length ic))
  in
  let key =
    match X509.Private_key.decode_pem key_pem with
    | Ok key -> key
    | Error (`Msg m) -> failwith (Printf.sprintf "Ca.load: %s: %s" key_path m)
  in
  (* Re-validate on the way back in, mirroring Tls_identity.create's own existing
     check_key_matches_cert -- a loaded (cert, key) pair must genuinely match, the same
     invariant generate_root/sign_leaf already guarantee for an in-memory Ca.t. *)
  (match Riptide_transport.Tls_identity.check_key_matches_cert ~cert ~priv_key:key with
   | () -> ()
   | exception _ -> failwith (Printf.sprintf "Ca.load: %s: private key does not match certificate %s" key_path cert_path));
  { key; cert }
```

Verify whether `Riptide_transport.Tls_identity.check_key_matches_cert` is actually exported/callable
from `lib/pki` (check for a dependency-direction issue — `lib/pki`'s own `dune` file may not
currently depend on `riptide_transport`, and `riptide_transport` already depends on `riptide_pki`
for `Ca.t`, per the just-merged plan's own Task 7→8 dependency, so depending on it back from `lib/pki`
would be a real cycle). If `check_key_matches_cert` is not reachable, duplicate the small check
locally in `ca.ml` instead (compare `X509.Public_key.fingerprint` of the cert's public key against
the private key's own derived public key, the same technique `tls_identity.ml`'s real, current
`check_key_matches_cert` already uses — read that function's real body first and mirror its logic,
not its name, if it can't be called directly).

`lib/pki/ca.mli` — add `val save : t -> dir:string -> unit` and `val load : dir:string -> t` with
real doc comments: what each does, the file names used, the permission requirement on the private
key file, and the failure modes (`Sys_error` on a missing directory/file, `Failure` on a malformed
PEM or a key/cert mismatch, `Invalid_argument` on bad permissions — matching this codebase's
existing convention of documenting `@raise` accurately per function, established by `Dek`/`Kek`'s
own `.mli` files).

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force`
Expected: both new tests `[OK]`, full suite otherwise unchanged.

- [ ] **Step 5: Commit**

```bash
git add lib/pki/ca.ml lib/pki/ca.mli test/test_pki.ml
git commit -m "pki: Ca.save/load -- real PEM persistence for the self-managed CA, closing subtask 4.7"
```

---

### Task 6: Replica commit-advanced trigger hook (subtask 3.7, part 1 of 3)

**Files:**
- Modify: `lib/vsr/replica.ml`, `lib/vsr/replica.mli`
- Test: `test/test_vsr_replica.ml` (extend)

**Interfaces:**
- Consumes: nothing from other tasks in this plan.
- Produces: `Replica.create` gains `?on_commit_advanced:(old_commit:int -> new_commit:int -> unit)`,
  invoked synchronously at every point `commit_number` updates. Consumed by Task 8.

**Context, already confirmed by direct code reading:** `t.commit_number <-` is assigned at exactly
four sites in `lib/vsr/replica.ml`: line 833 (the primary's own commit, inside
`primary_execute_op`), line 924 (a follower processing piggybacked commit info inside
`handle_prepare_ok` or a neighboring handler — confirm exact function against real code), line 1374
(view-change related, inside the `Start_view` handling path), and line 1701 (piggybacked commit
info inside `handle_prepare`). `Replica.create`'s real, current signature (`lib/vsr/replica.mli:108-113`):
`my_id:int -> replica_count:int -> svc_limit:int -> send:(to_:int -> string -> unit) -> storage:storage -> t`.

- [ ] **Step 1: Write the failing test**

`test/test_vsr_replica.ml` — read the real, current file's helpers for building a solo replica and
driving it through a commit first, then add:

```ocaml
let test_on_commit_advanced_fires_with_the_correct_before_and_after_values () =
  let observed = ref [] in
  let replica =
    Replica.create ~my_id:1 ~replica_count:1 ~svc_limit:10
      ~send:(fun ~to_:_ _ -> ())
      ~storage:(Replica.volatile_storage ())
      ~on_commit_advanced:(fun ~old_commit ~new_commit -> observed := (old_commit, new_commit) :: !observed)
  in
  Replica.for_test_set_view_number replica 1;
  Replica.propose replica (Riptide.Value.Scalar (Riptide.Value.String "op-1"));
  Replica.propose replica (Riptide.Value.Scalar (Riptide.Value.String "op-2"));
  Alcotest.(check (list (pair int int))) "commit_number advanced from 0->1, then 1->2, in order"
    [ (1, 2); (0, 1) ] (* most-recent-first, matching the accumulation order above *)
    !observed
```

Confirm `Replica.propose`'s real, current signature/behavior for a solo (`replica_count = 1`)
replica (it should commit synchronously, per this project's own already-established
`replica_count = 1` precedent used throughout the just-merged plan's own tests) before finalizing
this test's exact shape.

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i on_commit_advanced`
Expected: compile failure — `on_commit_advanced` is not a recognized labelled argument to
`Replica.create` yet.

- [ ] **Step 3: Implement the hook**

Read the real, current `Replica.create` and the `t` record type definition in `lib/vsr/replica.ml`
in full before editing. Add a field to `t` holding the optional callback:

```ocaml
(* In the t record: *)
on_commit_advanced : (old_commit:int -> new_commit:int -> unit) option;

(* In create: *)
let create ~my_id ~replica_count ~svc_limit ~send ~storage ?on_commit_advanced () =
  (* Note: adding an optional argument AFTER the existing required ones needs a trailing
     unit if create currently has no trailing unit -- verify against the real, current
     signature; OCaml's optional-argument-erasure rule means a bare optional argument
     with nothing concrete after it can silently fail to apply. If create's real signature
     already ends in a required argument, ?on_commit_advanced can be inserted before it
     without needing a new trailing (); check the real code before assuming either shape. *)
  { my_id; replica_count; svc_limit; send; storage; on_commit_advanced; (* ...existing fields... *) }
```

Add a small internal helper, called at every one of the four confirmed `commit_number <-` sites
instead of assigning `t.commit_number` directly:

```ocaml
let advance_commit_number t new_commit =
  let old_commit = t.commit_number in
  t.commit_number <- new_commit;
  match t.on_commit_advanced with
  | None -> ()
  | Some f -> f ~old_commit ~new_commit
```

Replace each of the four real, current `t.commit_number <- <expr>` assignments
(`replica.ml:833`, `:924`, `:1374`, `:1701` — confirm each site's real surrounding code first, since
line numbers shift as earlier tasks in this plan land commits) with
`advance_commit_number t <expr>`. Verify each site's `<expr>` doesn't itself read `t.commit_number`
in a way that would be affected by moving the read before the write (the helper reads
`t.commit_number` for `old_commit` before overwriting it, which should match the existing
assignment's own implicit "old value was whatever was there before" semantics at each site).

`lib/vsr/replica.mli` — document `?on_commit_advanced` on `create`'s own doc comment: it is invoked
synchronously, exactly once per distinct increase in `commit_number` (never for a no-op
"re-assignment" to the same value — verify each of the four real call sites actually only assigns
when the value is genuinely increasing, which the existing guards like `if k > t.commit_number then ...`
at some sites already suggest, but confirm this holds at all four before documenting it as a
guarantee), takes only integers so `Replica` stays domain-agnostic about what commit-advancement
means, and — importantly — is **not** invoked retroactively at `create` time for commits the
replica already knew about before this hook was attached (e.g. on restart) — a caller (Task 8) that
needs restart-time catch-up must handle that separately.

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force`
Expected: the new test `[OK]`, full suite otherwise unchanged (confirm no existing test constructs
`Replica.create` positionally in a way this new optional argument's insertion point would break —
OCaml's labelled/optional arguments are order-independent among themselves, but check anyway).

- [ ] **Step 5: Commit**

```bash
git add lib/vsr/replica.ml lib/vsr/replica.mli test/test_vsr_replica.ml
git commit -m "vsr: Replica.create gains ?on_commit_advanced, a domain-agnostic commit-progress hook -- part 1 of subtask 3.7"
```

---

### Task 7: File_storage eviction gate primitive (subtask 3.7, part 2 of 3)

**Files:**
- Modify: `lib/storage/file_storage.ml`, `lib/storage/file_storage.mli`
- Test: `test/test_file_storage.ml` (extend)

**Interfaces:**
- Consumes: nothing from other tasks in this plan.
- Produces: `File_storage.create` gains `?may_evict:(op_number:int -> bool)`; `wal_append` raises
  `Invalid_argument` with the message `"wal_append: eviction blocked for op_number <n>"` (a new,
  classifiable message shape, deliberately **not** a new custom exception type — see the design
  refinement below) when the predicate returns `false` for a genuine eviction. Consumed by Task 8.

**Context, already confirmed by direct code reading:** `wal_append` (`lib/storage/file_storage.ml:287-303`)
writes to `slot = (op_number - 1) mod t.ring_capacity`; that slot holds a live prior entry (i.e.
this write is a genuine eviction, not a first-time write into a fresh slot) exactly when
`op_number > t.ring_capacity`, and the op-number being evicted is `op_number - t.ring_capacity`.
`File_storage.create`'s real, current signature (`lib/storage/file_storage.mli:13-14`):
`sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> ring_capacity:int -> string -> t`.

**Design refinement versus the spec's own provisional framing, made now that the real code is in
front of us:** `lib/vsr/replica.ml` already has a real, tested, established pathway for exactly
this situation — "a storage backend declines a `wal_append`" — that this task should plug into
rather than duplicate. `Replica.durable_append` (`replica.ml:631-641`) already catches
`Invalid_argument` from `wal_append`, classifies the message via `classify_append_refusal`
(`replica.ml:147-151`) into one of three existing `append_refusal` shapes (`Fault_injection_cap`,
`Entry_rejected`, `Out_of_sequence`, matched by exact message prefix — `"wal_append: entry of "`
and `"wal_append: op_number "` are two of the three prefixes already reserved for this purpose),
counts it, and returns `false` rather than raising further — and **both of `durable_append`'s real
callers already treat a `false` return as a pure, silent no-op**: `propose` (`replica.ml:861`,
inside `if durable_append t ~op_number:n v then begin ... end`, no `else` at all) and
`handle_prepare` (`replica.ml:887-889`, whose own comment states it plainly: "The backend refused
the write, so the entry is NOT durable and must NOT be acknowledged... Total no-op, exactly like
any other guard failure here"). This is VSR's own established philosophy for a declined append —
the caller's ordinary retry semantics (a client retrying an unacknowledged request; a primary
simply not broadcasting `Prepare` for an op it couldn't durably store) already produce eventual
progress once whatever blocked the append clears, with **no new backoff loop, no new clock
dependency, and no new failure-escalation path needed anywhere in `Replica`**.

So: `wal_append` raises `Invalid_argument` with a message matching this project's own existing
prefix convention, **not** a bespoke exception type — Task 8 adds a fourth `append_refusal` variant
recognizing it, and `durable_append`/`propose`/`handle_prepare` need **zero** code changes beyond
that classification, since the existing "classify and silently decline" machinery already handles
any newly-recognized shape automatically. This is a real, grounded simplification versus the
spec's own provisional "bounded retry/backoff" framing, found only by reading `replica.ml` before
writing this task's code rather than assuming the spec's sketch was the final shape.

- [ ] **Step 1: Write the failing test**

`test/test_file_storage.ml` — read the real, current file's helpers for building a `File_storage.t`
first, then add:

```ocaml
let test_may_evict_blocks_a_genuine_eviction () =
  Eio_main.run @@ fun env ->
  let dir = Filename.temp_file "riptide_evict_test" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let t =
        File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2
          ~may_evict:(fun ~op_number -> op_number > 1 (* only op 1 is refused *))
          dir
      in
      File_storage.wal_append t ~op_number:1 "a";
      File_storage.wal_append t ~op_number:2 "b";
      (* op_number 3 would evict op_number 1's slot -- the predicate refuses op_number 1.
         Invalid_argument with a classifiable "wal_append: eviction blocked for op_number "
         prefix, matching this module's own two existing refusal-message shapes -- deliberately
         not a new custom exception type (see this task's own design-refinement note above). *)
      Alcotest.check_raises "eviction of a blocked op-number raises, classifiably"
        (Invalid_argument "wal_append: eviction blocked for op_number 1")
        (fun () -> File_storage.wal_append t ~op_number:3 "c"))

let test_may_evict_allows_a_permitted_eviction () =
  Eio_main.run @@ fun env ->
  let dir = Filename.temp_file "riptide_evict_test2" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2 ~may_evict:(fun ~op_number:_ -> true) dir in
      File_storage.wal_append t ~op_number:1 "a";
      File_storage.wal_append t ~op_number:2 "b";
      File_storage.wal_append t ~op_number:3 "c";
      Alcotest.(check (option string)) "op 3 landed, op 1's slot was reused" (Some "c")
        (File_storage.wal_read t ~op_number:3))

let test_no_may_evict_supplied_is_unaffected () =
  (* Backward compatibility: existing callers that omit ~may_evict see identical behavior. *)
  Eio_main.run @@ fun env ->
  let dir = Filename.temp_file "riptide_evict_test3" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2 dir in
      File_storage.wal_append t ~op_number:1 "a";
      File_storage.wal_append t ~op_number:2 "b";
      File_storage.wal_append t ~op_number:3 "c";
      Alcotest.(check (option string)) "eviction proceeds as before with no predicate" (Some "c")
        (File_storage.wal_read t ~op_number:3))
```

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i may_evict`
Expected: compile failure — `may_evict` is not a recognized labelled argument to
`File_storage.create` yet.

- [ ] **Step 3: Implement the gate**

Read the real, current `File_storage.create` and `wal_append` (`lib/storage/file_storage.ml:276-303`)
in full before editing. Add `may_evict : (op_number:int -> bool) option` to the `t` record type,
threaded through `create`'s own new `?may_evict` argument (matching the same "existing required
args, then this new optional one, verify whether a trailing `()` is needed" caveat already noted in
Task 6). Inside `wal_append` (`file_storage.ml:287-303`), before the existing body runs:

```ocaml
let wal_append t ~op_number data =
  if op_number <> t.highest_op_number + 1 then
    invalid_arg (* ...existing check, unchanged... *)
  else begin
    if op_number > t.ring_capacity then begin
      let evicted_op_number = op_number - t.ring_capacity in
      match t.may_evict with
      | None -> ()
      | Some predicate ->
        if not (predicate ~op_number:evicted_op_number) then
          (* Matches this module's own existing two refusal-message prefixes
             ("wal_append: entry of ", "wal_append: op_number ") exactly, so
             Replica.classify_append_refusal (Task 8) can recognize this as a third,
             equally real shape -- deliberately not a new exception type. *)
          invalid_arg (Printf.sprintf "wal_append: eviction blocked for op_number %d" evicted_op_number)
    end;
    (* ...existing body, unchanged: length check, slot write, highest_op_number update... *)
  end
```

`lib/storage/file_storage.mli` — document `?may_evict` on `create`'s own doc comment: what triggers
the check (a genuine eviction, i.e. `op_number > ring_capacity`, never a first-time write into a
still-fresh slot), that the predicate receives the op-number *about to be evicted*, not the new
op-number being written, that a refused eviction raises `Invalid_argument` with the
`"wal_append: eviction blocked for op_number "` prefix (cross-reference
`Riptide_vsr.Replica`'s own `classify_append_refusal`, which Task 8 extends to recognize it as a
normal, expected refusal shape — not a bug, and not something this module retries internally), and
that omitting `?may_evict` preserves this module's exact pre-existing behavior.

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force`
Expected: all three new tests `[OK]`, full suite otherwise unchanged.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/file_storage.ml lib/storage/file_storage.mli test/test_file_storage.ml
git commit -m "storage: File_storage.create gains ?may_evict, refusing a blocked eviction with a classifiable Invalid_argument instead of silently evicting -- part 2 of subtask 3.7"
```

---

### Task 8: Wire the watermark end to end, and prove it closes the general case (subtask 3.7, part 3 of 3)

**Files:**
- Modify: `lib/batch_commit/batch_commit.ml`, `lib/batch_commit/batch_commit.mli`
- Test: `test/test_lattice_materialize_crypto_scenarios.ml` (extend, reusing this file's own
  established multi-replica, fault-injecting harness conventions from the just-merged plan's own
  Task 9)

**Interfaces:**
- Consumes: `Riptide_vsr.Replica.create`'s `?on_commit_advanced` (Task 6), `File_storage.create`'s
  `?may_evict` and its new `"wal_append: eviction blocked for op_number "` refusal message
  (Task 7), `Batch_commit`'s existing `materialize_sink`, `committed_writes_for`, `already_in_log`.
- Produces: `Riptide_vsr.Replica`'s `append_refusal` type gains a fourth `Eviction_blocked` variant
  (recognized, not newly invented — see Step 2); a real, working, tested closure of subtask 3.7 for
  the general `replica_count >= 3` case. No later task in this plan depends on this one's own new
  exports.

**This is the task with the most genuine, real design judgment left — read the real, current code
before writing anything, per this project's own established discipline for exactly this kind of
integration point.** The pieces (Task 6's hook, Task 7's gate) are both real and tested in
isolation; this task's job is wiring them together through `Batch_commit` and proving the
end-to-end property, without introducing a new failure mode in VSR's own commit path.

- [ ] **Step 1: Design `materialize_up_to` and wire the trigger**

Read the real, current `Batch_commit.committed_writes_for` (`lib/batch_commit/batch_commit.ml:115-150`,
confirmed real from earlier investigation) and `committed_envelopes_keyed`
(`lib/batch_commit/batch_commit.mli:83`) in full — this task generalizes the per-key drain into a
range-based one over the same underlying committed-envelope data:

```ocaml
(* Materializes every merge_key-carrying write committed between the last-observed watermark
   and through_commit_number (inclusive), in commit order. Idempotent: re-running over an
   already-materialized range is a safe no-op, since Materializer.write is a lattice join. *)
val materialize_up_to :
  Riptide_vsr.Replica.t -> materialize:materialize_sink -> through_commit_number:int -> unit
```

Implement it by walking `committed_envelopes_keyed t` (or a lower-level equivalent that exposes
each committed batch's own writes, not just its envelope — check whether `committed_writes_for`'s
own internals expose a reusable "decode a committed batch's writes" helper that both functions can
share, rather than duplicating that decode logic) filtered to batches at or below
`through_commit_number`, and for each, materializing every write whose `merge_key` is set —
matching the existing per-key drain's own established discipline (writes with no `merge_key` are
silently skipped, unchanged from every other materialize call site in this module).

Wire `Replica.create`'s new `?on_commit_advanced` into `Batch_commit`: since `Batch_commit` itself
has no persistent state or construction site (confirmed in Task 3's own investigation), this hook
must be supplied by whoever constructs the `Replica.t` in the first place, wired to call
`Batch_commit.materialize_up_to t ~materialize:sink ~through_commit_number:new_commit` — document
this clearly in `batch_commit.mli` as the intended real-deployment wiring pattern (a caller building
a real replica passes
`~on_commit_advanced:(fun ~old_commit:_ ~new_commit -> Batch_commit.materialize_up_to replica ~materialize:sink ~through_commit_number:new_commit)`
to `Replica.create`), since `Batch_commit` cannot wire this itself without depending on `Replica`'s
own construction, which — per this module's own established, deliberate boundary — it does not do.

- [ ] **Step 2: Classify the new refusal shape, and wire the eviction gate's predicate**

**What a blocked eviction means for VSR's own commit path is already answered by real, existing,
tested code — confirmed by reading `replica.ml` in full before writing this step, not guessed.**
`Replica.durable_append` (`replica.ml:631-641`) already catches `Invalid_argument` from
`wal_append`, classifies it via `classify_append_refusal` (`replica.ml:124-151`) into one of three
existing `append_refusal` shapes, and both of its real callers — `propose` (`replica.ml:861`) and
`handle_prepare` (`replica.ml:887-889`) — already treat a classified refusal as a pure, silent
no-op, relying on VSR's own ordinary retry semantics for eventual progress. Task 7's new
`"wal_append: eviction blocked for op_number "` message is a fourth instance of exactly this
existing shape, not a new failure mode. This step's only real work is registering it:

```ocaml
(* In replica.ml, extending the existing three-variant type: *)
type append_refusal = Fault_injection_cap | Entry_rejected | Out_of_sequence | Eviction_blocked

let append_refusal_kinds = [ Fault_injection_cap; Entry_rejected; Out_of_sequence; Eviction_blocked ]

let append_refusal_index = function
  | Fault_injection_cap -> 0
  | Entry_rejected -> 1
  | Out_of_sequence -> 2
  | Eviction_blocked -> 3

let append_refusal_name = function
  | Fault_injection_cap -> "fault_injection_cap"
  | Entry_rejected -> "entry_rejected"
  | Out_of_sequence -> "out_of_sequence"
  | Eviction_blocked -> "eviction_blocked"

let classify_append_refusal msg =
  if String.equal msg "faults_max exceeded" then Some Fault_injection_cap
  else if String.starts_with ~prefix:"wal_append: entry of " msg then Some Entry_rejected
  else if String.starts_with ~prefix:"wal_append: op_number " msg then Some Out_of_sequence
  else if String.starts_with ~prefix:"wal_append: eviction blocked for op_number " msg then Some Eviction_blocked
  else None
```

`append_refusals : int array`'s size is already derived from `List.length append_refusal_kinds`
(`replica.ml:407`), so it grows automatically — no other change needed there. Update
`test_vsr_replica_recovery.ml`'s existing discrimination test (referenced in `classify_append_refusal`'s
own doc comment as pinning "the real exceptions those modules raise land in the intended buckets")
to add a fourth case proving a genuine `Eviction_blocked` refusal from Task 7's `File_storage`
lands in this new bucket, the same way the existing three are already pinned — read that test's
real, current structure first and match its own conventions.

**Reconciling this with the spec's own "loud, distinguishable, never a silent wedge" requirement
for Decision 2, now that real code reading has settled the mechanism:** a declined append here is
*silent* in the sense that already applies to every other refusal kind — no exception escapes
`Replica.propose`, and this is deliberately consistent with this codebase's own established
philosophy, not a gap. What makes it *not* a silent wedge is that it is *counted*, the same way the
other three refusal kinds already are — but `for_test_append_refusals`
(`lib/vsr/replica.mli:829-838`) is currently documented as "Diagnostics, not protocol... nothing in
this module reads it," meaning today this signal is test-only, not something a real deployment can
actually observe. Add a real, non-test-prefixed accessor alongside it:

```ocaml
val append_refusals : t -> (string * int) list
(** The production-facing form of {!for_test_append_refusals} -- same data, same [(name, count)]
    shape, intended for a real deployment's own monitoring/alerting to poll. A caller watching
    [eviction_blocked]'s count grow without bound, alongside [commit_number] failing to advance,
    is the real signal that materialization has genuinely fallen behind -- this is what "loud,
    not a silent wedge" means in practice: real data is never lost (the write stays durably
    logged and gets retried), and the condition is genuinely observable, even though no exception
    propagates out of a single [propose]/[handle_prepare] call. *)
val for_test_append_refusals : t -> (string * int) list
```

(Or, if duplicating the accessor feels wrong once you're looking at the real code, rename
`for_test_append_refusals` to the plain, production-facing name and update its doc comment and
every existing test call site — whichever is the smaller, more consistent change against the real
current file. Either way, the net effect must be: a real caller, not just a test, can read these
counts.)

**Now wire the actual predicate.** `File_storage`'s `?may_evict` needs to answer "has op-number N
been materialized (or does it not need to be, because it carries no `merge_key`)?" — which requires
threading a watermark value from `Batch_commit`'s own materialization progress down into whichever
`File_storage.t` backs the replica's storage. Read the real, current
`Riptide_vsr.Replica.storage_of_module` (used by `lib/dst/cluster.ml` to erase a concrete storage
module's type, confirmed to exist from this plan's own earlier investigation) to see how `Replica`'s
own `storage` value relates to the concrete `File_storage.t` a real deployment constructs, then
extend `materialize_up_to` (Step 1) to also track the highest commit_number it has fully
materialized through — a plain `int ref` owned by whoever wires `?on_commit_advanced` and
`?may_evict` together (the same real-deployment caller code documented in Step 1's own
`batch_commit.mli` addition — `Batch_commit` itself stays stateless, per Task 3's own confirmed
design). Build the predicate as:

```ocaml
let watermark = ref 0 in
let on_commit_advanced ~old_commit:_ ~new_commit =
  Batch_commit.materialize_up_to replica ~materialize:sink ~through_commit_number:new_commit;
  watermark := new_commit
in
let may_evict ~op_number =
  op_number <= !watermark || not (Batch_commit.write_at_op_number_has_merge_key replica ~op_number)
in
(* both passed to Replica.create / File_storage.create respectively, at real replica construction
   time -- see Step 1's own batch_commit.mli documentation of this wiring pattern. *)
```

`Batch_commit.write_at_op_number_has_merge_key` is a small new helper this step adds, decoding one
committed envelope's write metadata the same way `committed_writes_for`/`materialize_up_to`
themselves already do — reuse that decode logic rather than duplicating it (verify against the real,
current code whether a shared internal helper already exists to extract this, or whether one is
worth factoring out now that three call sites need the same decode).

- [ ] **Step 3: Write the end-to-end proof, reusing the just-merged plan's own adversarial harness**

`test/test_lattice_materialize_crypto_scenarios.ml` already has (from the just-merged plan's own
Task 9) a real 5-replica, fault-injecting harness with per-replica `File_kv_store`-backed
`Materializer`s. Read that file's real, current shape in full before writing this task's own new
test — reuse its harness conventions rather than building a new one.

Write a real, multi-replica scenario proving the specific case subtask 3.7 has been open about
since before the just-merged plan started: a **follower** (not the primary, not an
operator-driven manual drain) whose ring would have evicted a committed, `merge_key`-carrying entry
before it was ever materialized — proven safe now, because (a) the follower's own
`?on_commit_advanced` hook fires automatically off `handle_message` processing a piggybacked commit
(no explicit `propose ~materialize` call from a caller), and (b) if materialization genuinely can't
keep up (simulate this: a fault-injected/deliberately-slow materializer, or a scenario that proposes
far faster than the harness drains), assert two things together, matching the reconciled design
from Step 2: the entry is never lost (it stays durably in the WAL and eventually gets both
committed and materialized once the backlog clears — no data destroyed, no wedge that never
resolves) *and* the new `append_refusals`/`eviction_blocked` count genuinely rises during the
backlog window, proving the condition was real and observable, not silently invisible.

Add a second, explicit assertion in the same scenario (this plan's own Review Focus item on 3.7):
interleave writes that never set `merge_key` into the same backlog-heavy run, and confirm none of
them ever trip `?may_evict`/increment `eviction_blocked` — the existing, disclosed boundary (a
non-materialized write is exactly as vulnerable to eviction as before this whole effort) must stay
completely unaffected by the new gate, proven directly rather than only implied by the predicate's
own `|| not (... has_merge_key ...)` logic.

Non-vacuity proof, matching this whole plan's own established discipline (Tasks 5, 6, 7, 9 of the
just-merged plan all did this): temporarily revert this task's own `?on_commit_advanced` wiring (or
construct a variant harness with it disabled) and confirm the new test genuinely fails — a follower
whose ring evicts an unmaterialized entry with the hook disabled, proving the test has real power to
catch the exact regression this task closes — then confirm it passes with the wiring in place.

- [ ] **Step 4: Run to verify pass, and run the whole suite repeatedly**

Run: `dune clean && dune build && dune test --force`, at least 3 times, confirming stability
(this task sits directly on top of Task 1's own determinism fix — if this new multi-replica test is
itself flaky, investigate whether it's hitting the same class of real-I/O-timing sensitivity Task 1
closed, or a genuinely new one, before concluding it's done).

- [ ] **Step 5: Commit**

```bash
git add lib/batch_commit/batch_commit.ml lib/batch_commit/batch_commit.mli test/test_lattice_materialize_crypto_scenarios.ml
git commit -m "batch_commit: wire the general multi-replica ring-eviction watermark end to end, closing subtask 3.7 for real"
```

---
