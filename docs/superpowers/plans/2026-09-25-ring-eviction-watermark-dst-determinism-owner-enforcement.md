# Ring-Eviction Watermark, DST Determinism, Owner Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close task-master subtasks 3.7 (general multi-replica ring-eviction watermark), 3.8 (the
real, decisively-proven DST completion flake), and 4.8 (type-level owner enforcement for
`Redaction_store.create`).

**Architecture:** Six tasks. Task 1 (3.8) goes first — 3.7's own new multi-replica tests need a
non-flaky DST harness underneath them. Task 2 (4.8) is small and independent, and can land
anywhere; placed second since it's cheap and unblocks nothing else. Tasks 3-6 are subtask 3.7's
own four pieces (trigger, gate, drain, integration+proof), built bottom-up: each of Tasks 3-5
produces one small, independently-testable primitive: Task 6 wires them together and delivers the
real end-to-end proof.

**Tech Stack:** OCaml 5, Eio, this repo's own `Riptide_vsr`/`Riptide_storage`/
`Riptide_batch_commit`/`Riptide_sim`/`Riptide_dst`/`Riptide_crypto` libraries.

**Spec:** `docs/superpowers/specs/2026-09-25-ring-eviction-watermark-dst-determinism-owner-enforcement-design.md`

## Global Constraints

- Subtask 3.7's trigger hook on `Riptide_vsr.Replica` takes only integers
  (`old_commit:int -> new_commit:int -> unit`) — `Replica` must stay domain-agnostic, never
  learning about materialization, redaction, or `Value.value`.
- Subtask 3.7's gate reuses `Replica`'s existing `append_refusal` classification machinery — a
  fourth variant, not a new exception type, and no new backoff/retry/clock dependency introduced
  into `Replica` or `File_storage`.
- A write whose `merge_key` was never set remains exactly as vulnerable to ring eviction as before
  this whole materialization effort — an existing, unchanged, disclosed boundary.
- Subtask 3.8's fix must not touch `run`'s own mock-backend completion path (`Eio_mock.Backend`,
  no real I/O) — only `run_on_file_storage`'s real-`File_storage` path is in scope. The real
  wall-clock `Eio.Time.sleep` inside `wait_io` is legitimate and must not be removed.
- Subtask 4.8's fix closes only `Redaction_store.create`'s half — `Materializer.create` stays
  convention-only, deliberately, per the spec's own Decision 6 reasoning (it is generic over any
  `Kv_store_intf.S` backend, which carries no ownership concept).
- Every task ships with real, running, tested code in the same change that introduces any rule it
  establishes, per this repo's `CLAUDE.md` "no spec without running code" rule.

## Review Focus

- **A blocked eviction must be a silent, retried no-op, exactly like the three existing refusal
  kinds — never a new exception escaping `Replica.propose`/`handle_prepare`.** A reasonable person
  reading "the ring refuses to evict" would expect this to behave like every other declined
  durable append already does in this codebase, not introduce a new failure mode a caller has to
  learn to handle. (3.7, Task 4)
- **A write with no `merge_key` must be completely unaffected by the new eviction gate**, at every
  point in a real backlog, not just in the common case. (3.7, Task 4/6)
- **Restart recovery must genuinely require no new durable state.** A replica that restarts and
  re-materializes through its own current `commit_number` must converge to the same state a
  never-restarted replica would have — proven, not just claimed to follow from lattice-join
  idempotence. (3.7, Task 6)
- **The DST determinism fix must still detect a genuinely stuck cluster**, not just stop detecting
  a merely-slow one. A fix that silently disables `Did_not_settle` entirely would pass every
  existing test while deleting the harness's own livelock detection. (3.8, Task 1)
- **`Redaction_store.create`'s new rejection must fire before any keystore operation touches the
  mismatched directory** — a reasonable person expects "rejected at construction" to mean
  construction, not "rejected on first use." (4.8, Task 2)

---

### Task 1: Progress-based DST completion budget (subtask 3.8)

**Files:**
- Modify: `lib/dst/cluster.ml`
- Test: `test/test_dst_scenarios.ml` (extend)

**Interfaces:**
- Consumes: nothing from later tasks.
- Produces: `with_cluster` gains `?max_wait_duration:float`; `run_on_file_storage` supplies it.
  Nothing later depends on this task's own new exports — it's a standalone reliability fix.

**Context, already confirmed by direct code reading:** `lib/dst/cluster.ml:170-203`'s `settle`
bounds its I/O-wait branch with a fixed `io_waits : int` countdown (`loop delivery_rounds 5000` at
`:203`, decremented at `:198`). `run_on_file_storage` (`:302-330`) has a real `Eio.Time.clock` via
`Eio.Stdenv.clock env` (`:315`), already used inside `wait_io`'s own closure (`:329`,
`fun () -> Eio.Time.sleep clock 0.0001`). `run`'s own entry point (`:274-301`) enters
`Eio_mock.Backend.run` directly with no `~env` and no access to a real clock — and per this file's
own existing comment, `inflight` returns to zero after the first yield of every round under that
backend, so its `io_waits` branch is never meaningfully exercised there. `Eio.Time.now : _ clock ->
float` is confirmed real (`/work/toolchain/opam-root/5.0.0/lib/eio/time.mli:8`).

- [ ] **Step 1: Quantify the current load-sensitivity, for a real before/after**

Before touching any code, reproduce the load-sensitivity this plan's own investigation already
found (during the just-merged plan's own subtask 4.7 work): run the previously-flaky scenario
under real induced CPU load and confirm it still fails today.

```bash
# Start real background load (adjust busy-loop count to roughly 2x this machine's core count):
for i in $(seq 1 32); do (while true; do :; done) & done
LOAD_PIDS=$(jobs -p)

# Run the scenario 5 times under load:
for i in $(seq 1 5); do dune exec test/test_riptide.exe -- test dst_scenarios 8 2>&1 | tail -3; done

# Stop the load:
kill $LOAD_PIDS 2>/dev/null
```

Expected: at least one, likely most, of the 5 runs fail with `Did_not_settle` or the suite's own
15s watchdog. Record the exact failure count — this is your baseline.

- [ ] **Step 2: Write the failing genuinely-stuck-forever test**

`test/test_dst_scenarios.ml` — read the real, current file's helpers for constructing a
`Fault_injecting_storage`/`File_storage`-backed cluster first, then add a test proving the fix
does NOT silently disable livelock detection. The cleanest real way to construct genuine,
permanent non-progress: inject a storage fault that makes the primary's own slot unreadable before
any op commits (this file already documents, in `test_lattice_materialize_crypto_scenarios.ml`'s
own header, that this VSR subset's `primary_execute_op` refuses to commit an op it cannot itself
read back, and with no view change in scope, this is real, permanent non-progress, not a timing
fluke):

```ocaml
let test_settle_still_raises_did_not_settle_when_genuinely_stuck () =
  Eio_main.run @@ fun env ->
  let dir = make_tmp_dir "riptide_stuck_test" in
  Fun.protect ~finally:(fun () -> rm_rf dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  (* Build a real 3-replica cluster over File_storage, using this file's own existing
     run_on_file_storage-based helper conventions -- read the real, current file for the exact
     construction pattern (env/dir/seed/replica_count) before writing this. *)
  Alcotest.check_raises "a permanently stuck cluster still raises Did_not_settle"
    Riptide_dst.Cluster.Did_not_settle
    (fun () ->
      Riptide_dst.Cluster.run_on_file_storage ~env ~dir ~seed:1 ~replica_count:3
        ~max_wait_duration:1.0 (* short, since this test wants the stuck case to time out fast *)
        (fun ~replicas ~settle ~restart:_ ->
          (* Corrupt the primary's own first slot before it ever commits, using
             Fault_injecting_storage.for_test_corrupt_entry -- read the real, current signature
             from test_lattice_materialize_crypto_scenarios.ml's own use of it before writing
             this. Then propose one op and call settle -- it must never quiesce. *)
          ignore replicas;
          settle ()))
```

Confirm `Riptide_dst.Cluster.Did_not_settle`'s exact real exception name/shape against the current
file before finalizing this test.

- [ ] **Step 2b: Run to verify failure for the right reason**

Run: `dune build 2>&1 | grep -i max_wait_duration`
Expected: compile failure — `max_wait_duration` is not a recognized labelled argument yet.

- [ ] **Step 3: Implement the progress-based budget**

Read the real, current `with_cluster`/`settle`/`run_on_file_storage` (`lib/dst/cluster.ml:93-203,
302-330`) in full before editing — this plan does not restate their unchanged control flow.

```ocaml
(* In with_cluster's own argument list, alongside the existing ~wait_io ~delivery_rounds: *)
let with_cluster ~seed ~replica_count ~svc_limit ~net_fault_config ~storage_fault_config
    ~make_storage ~wait_io ~delivery_rounds ?max_wait_duration ?clock body =
  (* ...existing body, unchanged, down to settle's own definition... *)
  let settle () =
    (* ...existing comment about the two independent budgets, unchanged... *)
    let deadline = ref None in
    let start_deadline_tracking () =
      match (max_wait_duration, clock) with
      | Some max_d, Some clock -> deadline := Some (Eio.Time.now clock +. max_d)
      | _ -> ()
    in
    let deadline_exceeded clock_opt =
      match (deadline, clock_opt) with
      | { contents = Some d }, Some clock -> Eio.Time.now clock > d
      | _ -> false
    in
    let rec loop delivery_rounds io_waits =
      if delivery_rounds <= 0 then raise Did_not_settle
      else if max_wait_duration = None && io_waits <= 0 then raise Did_not_settle
      else begin
        let delivered = ref false in
        while Riptide_sim.Network.pump_one net do
          delivered := true;
          incr inflight
        done;
        Eio.Fiber.yield ();
        let delivery_rounds = if !delivered then delivery_rounds - 1 else delivery_rounds in
        if !delivered then start_deadline_tracking ();
        if !inflight > 0 then begin
          if deadline_exceeded clock then raise Did_not_settle;
          if !deadline = None then start_deadline_tracking ();
          wait_io ();
          loop delivery_rounds (io_waits - 1)
        end
        else if !delivered then loop delivery_rounds io_waits
      end
    in
    loop delivery_rounds 5000
  in
  (* ...rest of with_cluster, unchanged... *)
```

Verify this sketch's exact control flow against the real, current `settle` before finalizing —
this is a real design change to a load-bearing function, not a mechanical edit; in particular
confirm the deadline is genuinely reset on every real delivery (`!delivered`), not just once at
`settle`'s own start, matching the spec's own "quiet window since last real delivery" design.

`run_on_file_storage` (`:302-330`) passes `~max_wait_duration:30.0 ~clock` (using its own
already-available `clock = Eio.Stdenv.clock env`) — pick 30.0 as a generous default budget;
document the choice in a comment (this is a liveness bound for a genuinely stuck cluster, not a
tuning knob for normal operation, so err generous). `run` (`:274-301`) passes neither, keeping its
existing fixed-`io_waits`-only behavior exactly as before (both new parameters default to `None`).

- [ ] **Step 4: Run to verify the stuck-cluster test passes, and the load-sensitivity test in Step 1 no longer fails**

Run: `dune build && dune exec test/test_riptide.exe -- test dst_scenarios`
Expected: the new stuck-cluster test `[OK]`. Then repeat Step 1's load experiment against the
fixed code — expected: 0 failures across 5 runs under the same induced load.

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `dune clean && dune build && dune test --force`, at least 3 times.
Expected: identical pass count every time.

- [ ] **Step 6: Commit**

```bash
git add lib/dst/cluster.ml test/test_dst_scenarios.ml
git commit -m "dst: settle() tracks wall-clock time since last real delivery, not a raw attempt count -- closes subtask 3.8's real root cause"
```

---

### Task 2: `Redaction_store.create` type-level owner enforcement (subtask 4.8)

**Files:**
- Modify: `lib/storage/file_kv_store.ml`, `lib/storage/file_kv_store.mli`
- Modify: `lib/crypto/redaction_store.ml`, `lib/crypto/redaction_store.mli`
- Test: `test/test_file_kv_store.ml` (extend), `test/test_redaction.ml` (extend)

**Interfaces:**
- Consumes: `File_kv_store.t`'s existing `?owner:string` construction-time marker (subtask 4.6,
  already merged).
- Produces: `File_kv_store.owner : t -> string option`; `Redaction_store.owner_tag : string`.
  Nothing later in this plan depends on this task.

**Context, already confirmed by direct code reading:** `lib/storage/file_kv_store.ml:325-341`'s
`check_or_write_owner_marker` already reads/writes the marker file at construction — the tag it
resolves to is available in scope at that point, just not currently retained on `t` or exposed.
`lib/crypto/redaction_store.ml:8` is `let create ~kv ~kek = { kv; kek }` — receives an
already-built `kv`, does not construct one itself.

- [ ] **Step 1: Write the failing tests**

`test/test_file_kv_store.ml` — add:

```ocaml
let test_owner_reads_back_the_tag_used_at_construction () =
  Eio_main.run @@ fun env ->
  let dir = make_tmp_dir "riptide_kv_owner_readback_test" in
  Fun.protect ~finally:(fun () -> rm_rf dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"a-real-tag" dir in
  Alcotest.(check (option string)) "owner reads back the construction-time tag" (Some "a-real-tag")
    (File_kv_store.owner t)

let test_owner_is_none_when_no_tag_was_supplied () =
  Eio_main.run @@ fun env ->
  let dir = make_tmp_dir "riptide_kv_no_owner_readback_test" in
  Fun.protect ~finally:(fun () -> rm_rf dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
  Alcotest.(check (option string)) "no tag supplied reads back as None" None (File_kv_store.owner t)
```

(Confirm `make_tmp_dir`/`rm_rf` are this file's real, existing helper names — reuse them, don't
invent new ones.)

`test/test_redaction.ml` — read the real, current file's helpers for constructing a
`Redaction_store.t` (likely via `File_kv_store.create` + `Kek.of_raw`/similar) first, then add:

```ocaml
let test_create_rejects_a_kv_tagged_for_a_different_owner () =
  Eio_main.run @@ fun env ->
  let dir = make_tmp_dir "riptide_redaction_owner_test" in
  Fun.protect ~finally:(fun () -> rm_rf dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"some-other-owner" dir in
  let kek = (* this file's own existing real Kek construction helper *) in
  Alcotest.check_raises "a kv tagged for a different owner is rejected at construction"
    (Invalid_argument
       (Printf.sprintf "Redaction_store.create: kv is owned by \"some-other-owner\", expected %S"
          Redaction_store.owner_tag))
    (fun () -> ignore (Redaction_store.create ~kv ~kek))

let test_create_rejects_an_untagged_kv () =
  Eio_main.run @@ fun env ->
  let dir = make_tmp_dir "riptide_redaction_untagged_test" in
  Fun.protect ~finally:(fun () -> rm_rf dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
  let kek = (* same real Kek helper *) in
  Alcotest.check_raises "an untagged kv is rejected at construction"
    (Invalid_argument
       (Printf.sprintf "Redaction_store.create: kv is owned by %S, expected %S" "(none)"
          Redaction_store.owner_tag))
    (fun () -> ignore (Redaction_store.create ~kv ~kek))
```

Verify the exact real error-message format you want against your own Step 3 implementation before
finalizing these two tests' expected strings — write the implementation's message first if that's
cleaner, then match the tests to it exactly (either order is fine, but the two must agree
byte-for-byte, matching this project's own established `check_raises`-with-exact-message
convention).

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i "File_kv_store.owner\|owner_tag"`
Expected: compile failure — neither `File_kv_store.owner` nor `Redaction_store.owner_tag` exists
yet.

- [ ] **Step 3: Implement**

`lib/storage/file_kv_store.ml` — read the real, current `t` record type and
`check_or_write_owner_marker` (`:299-341`) in full before editing. Add an `owner : string option`
field to `t`, set from whatever `check_or_write_owner_marker` resolves the tag to be (the
caller-supplied `owner` argument itself, if supplied — since a construction that reaches this
point either matches the existing marker or wrote a fresh one with exactly this value; verify this
reasoning against the real function body, which may already return or otherwise make available the
resolved tag). Add:

```ocaml
let owner t = t.owner
```

`lib/storage/file_kv_store.mli` — add `val owner : t -> string option` with a real doc comment
(what it returns, that it reflects the marker file's actual on-disk content, not merely echoing
back whatever was passed to `create`).

`lib/crypto/redaction_store.ml` — read the real, current `create` (`:8`) in full, then:

```ocaml
let owner_tag = "redaction-keystore"

let create ~kv ~kek =
  let actual = Riptide_storage.File_kv_store.owner kv in
  if actual <> Some owner_tag then
    invalid_arg
      (Printf.sprintf "Redaction_store.create: kv is owned by %S, expected %S"
         (Option.value actual ~default:"(none)")
         owner_tag);
  { kv; kek }
```

`lib/crypto/redaction_store.mli` — add `val owner_tag : string` (exported, real, replacing the
prior plan's scattered `"redaction-keystore"` string literals across 7 call sites — update every
one of those 7 real call sites, found via `grep -rn '"redaction-keystore"'`, to reference
`Redaction_store.owner_tag` instead of repeating the literal) and document the new rejection on
`create`'s own doc comment, including the exact `@raise Invalid_argument` condition.

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force`
Expected: all 4 new tests `[OK]`, full suite otherwise unchanged.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/file_kv_store.ml lib/storage/file_kv_store.mli lib/crypto/redaction_store.ml lib/crypto/redaction_store.mli test/test_file_kv_store.ml test/test_redaction.ml
git commit -m "crypto: Redaction_store.create enforces its owner tag at construction, closing subtask 4.8's Redaction_store half"
```

---

### Task 3: Replica commit-advanced trigger hook (subtask 3.7, part 1 of 4)

**Files:**
- Modify: `lib/vsr/replica.ml`, `lib/vsr/replica.mli`
- Test: `test/test_vsr_replica.ml` (extend)

**Interfaces:**
- Consumes: nothing from other tasks in this plan.
- Produces: `Replica.create` gains `?on_commit_advanced:(old_commit:int -> new_commit:int -> unit)`,
  invoked synchronously at every point `commit_number` updates. Consumed by Task 6.

**Context, already confirmed by direct code reading:** `t.commit_number <-` is assigned at exactly
four sites in `lib/vsr/replica.ml`: line 833 (the primary's own commit, inside
`primary_execute_op`), line 924, line 1374 (inside `Start_view` handling), and line 1701 (inside
`handle_prepare`). `Replica.create`'s real, current signature (verify against the actual file
before editing — this repo's own established discipline; the just-merged plan's own equivalent
task found this needs re-confirming every time since optional-argument insertion order matters):
`my_id:int -> replica_count:int -> svc_limit:int -> send:(to_:int -> string -> unit) ->
storage:storage -> t`.

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
  Alcotest.(check (list (pair int int))) "commit_number advanced 0->1, then 1->2, in order"
    [ (1, 2); (0, 1) ]
    !observed

let test_no_hook_supplied_is_unaffected () =
  (* Backward compatibility: existing callers that omit ?on_commit_advanced see identical
     behaviour -- just re-run a simple propose/commit sequence with no hook at all. *)
  let replica =
    Replica.create ~my_id:1 ~replica_count:1 ~svc_limit:10 ~send:(fun ~to_:_ _ -> ())
      ~storage:(Replica.volatile_storage ())
  in
  Replica.for_test_set_view_number replica 1;
  Replica.propose replica (Riptide.Value.Scalar (Riptide.Value.String "op-1"));
  Alcotest.(check int) "committed without a hook" 1 (Replica.commit_number replica)
```

Confirm `Replica.propose`'s real, current behavior for a solo (`replica_count = 1`) replica (it
should commit synchronously, per this project's own already-established `replica_count = 1`
precedent used throughout the just-merged plan's own tests) before finalizing this test's exact
shape, and confirm `Replica.commit_number`'s real, current name/signature.

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
```

Add `?on_commit_advanced` to `create`'s own argument list (check the real, current signature for
whether a trailing `()` is needed for the optional-argument-erasure rule to apply correctly — if
`create` currently ends in a required argument, this can be inserted before it without a new
trailing unit; if it doesn't, verify carefully, since OCaml's optional-argument rules can silently
fail to apply an optional argument with nothing concrete after it).

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

Replace each of the four real, current `t.commit_number <- <expr>` assignments (`replica.ml:833`,
`:924`, `:1374`, `:1701`) with `advance_commit_number t <expr>`. Verify each site's `<expr>`
doesn't itself read `t.commit_number` in a way affected by moving the read before the write (the
helper reads `t.commit_number` for `old_commit` before overwriting it, matching each site's own
implicit "old value was whatever was there before" semantics).

`lib/vsr/replica.mli` — document `?on_commit_advanced` on `create`'s own doc comment: invoked
synchronously, exactly once per genuine increase in `commit_number` (confirm each of the four real
sites only assigns when genuinely increasing before documenting this as a guarantee — some sites'
existing guards like `if k > t.commit_number then ...` already suggest this holds), takes only
integers so `Replica` stays domain-agnostic, and is **not** invoked retroactively at `create` time
for commits the replica already knew about before this hook was attached (e.g. on restart) — a
caller that needs restart-time catch-up (Task 6) handles that separately.

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force`
Expected: both new tests `[OK]`, full suite otherwise unchanged (confirm no existing test
constructs `Replica.create` in a way this new optional argument's insertion point would break).

- [ ] **Step 5: Commit**

```bash
git add lib/vsr/replica.ml lib/vsr/replica.mli test/test_vsr_replica.ml
git commit -m "vsr: Replica.create gains ?on_commit_advanced, a domain-agnostic commit-progress hook -- part 1 of subtask 3.7"
```

---

### Task 4: File_storage eviction gate, refusal classification, and observability (subtask 3.7, part 2 of 4)

**Files:**
- Modify: `lib/storage/file_storage.ml`, `lib/storage/file_storage.mli`
- Modify: `lib/vsr/replica.ml`, `lib/vsr/replica.mli`
- Test: `test/test_file_storage.ml` (extend), `test/test_vsr_replica_recovery.ml` (extend)

**Interfaces:**
- Consumes: nothing from other tasks in this plan.
- Produces: `File_storage.create` gains `?may_evict:(op_number:int -> bool)`; `wal_append` raises
  `Invalid_argument "wal_append: eviction blocked for op_number <n>"` on a refused eviction.
  `Riptide_vsr.Replica`'s `append_refusal` type gains a fourth variant, `Eviction_blocked`.
  `Replica` gains a real, production-facing `append_refusals` accessor. Consumed by Task 6.

**Context, already confirmed by direct code reading:** `wal_append` (`lib/storage/file_storage.ml:287-303`)
writes to `slot = (op_number - 1) mod t.ring_capacity`; that slot holds a live prior entry (a
genuine eviction, not a first-time write into a fresh slot) exactly when `op_number >
t.ring_capacity`, and the op-number being evicted is `op_number - t.ring_capacity`.
`File_storage.create`'s real, current signature: `sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t ->
ring_capacity:int -> string -> t`. `Replica.durable_append` (`lib/vsr/replica.ml:631-641`) already
catches `Invalid_argument` from `wal_append`, classifies it via `classify_append_refusal`
(`:124-151`), and both of its real callers — `propose` (`:861`) and `handle_prepare` (`:887-889`)
— already treat a classified refusal as a pure, silent no-op. The existing `append_refusal` type,
verified real and current: `type append_refusal = Fault_injection_cap | Entry_rejected |
Out_of_sequence`, with `append_refusal_kinds`, `append_refusal_index`, `append_refusal_name`,
`classify_append_refusal` at `:124-151`, and `for_test_append_refusals` at `:1772-1774`
(documented "Diagnostics, not protocol... nothing in this module reads it").

- [ ] **Step 1: Write the failing tests for the gate itself**

`test/test_file_storage.ml` — read the real, current file's helpers for building a `File_storage.t`
first, then add:

```ocaml
let test_may_evict_blocks_a_genuine_eviction () =
  Eio_main.run @@ fun env ->
  let dir = make_tmp_dir "riptide_evict_test" in
  Fun.protect ~finally:(fun () -> rm_rf dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let t =
    File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2
      ~may_evict:(fun ~op_number -> op_number > 1 (* only op 1 is refused *))
      dir
  in
  File_storage.wal_append t ~op_number:1 "a";
  File_storage.wal_append t ~op_number:2 "b";
  (* op_number 3 would evict op_number 1's slot -- the predicate refuses op_number 1. *)
  Alcotest.check_raises "eviction of a blocked op-number raises, classifiably"
    (Invalid_argument "wal_append: eviction blocked for op_number 1")
    (fun () -> File_storage.wal_append t ~op_number:3 "c")

let test_may_evict_allows_a_permitted_eviction () =
  Eio_main.run @@ fun env ->
  let dir = make_tmp_dir "riptide_evict_test2" in
  Fun.protect ~finally:(fun () -> rm_rf dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2 ~may_evict:(fun ~op_number:_ -> true) dir in
  File_storage.wal_append t ~op_number:1 "a";
  File_storage.wal_append t ~op_number:2 "b";
  File_storage.wal_append t ~op_number:3 "c";
  Alcotest.(check (option string)) "op 3 landed, op 1's slot was reused" (Some "c")
    (File_storage.wal_read t ~op_number:3)

let test_no_may_evict_supplied_is_unaffected () =
  Eio_main.run @@ fun env ->
  let dir = make_tmp_dir "riptide_evict_test3" in
  Fun.protect ~finally:(fun () -> rm_rf dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2 dir in
  File_storage.wal_append t ~op_number:1 "a";
  File_storage.wal_append t ~op_number:2 "b";
  File_storage.wal_append t ~op_number:3 "c";
  Alcotest.(check (option string)) "eviction proceeds as before with no predicate" (Some "c")
    (File_storage.wal_read t ~op_number:3)
```

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i may_evict`
Expected: compile failure — `may_evict` is not a recognized labelled argument to
`File_storage.create` yet.

- [ ] **Step 3: Implement the gate**

Read the real, current `File_storage.create` and `wal_append` (`:276-303`) in full before editing.
Add `may_evict : (op_number:int -> bool) option` to the `t` record type, threaded through
`create`'s own new `?may_evict` argument (same optional-argument-position caveat as Task 3). Inside
`wal_append`, before the existing body runs:

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
          invalid_arg (Printf.sprintf "wal_append: eviction blocked for op_number %d" evicted_op_number)
    end;
    (* ...existing body, unchanged: length check, slot write, highest_op_number update... *)
  end
```

`lib/storage/file_storage.mli` — document `?may_evict` on `create`'s own doc comment: what
triggers the check, that the predicate receives the op-number *about to be evicted*, that a
refused eviction raises `Invalid_argument` with the `"wal_append: eviction blocked for op_number "`
prefix (cross-reference `Riptide_vsr.Replica`'s `classify_append_refusal`, which Step 4 below
extends to recognize it), and that omitting `?may_evict` preserves this module's exact pre-existing
behavior.

- [ ] **Step 4: Register the new refusal kind and promote the accessor**

Read the real, current `type append_refusal`/`append_refusal_kinds`/`append_refusal_index`/
`append_refusal_name`/`classify_append_refusal`/`for_test_append_refusals` (`lib/vsr/replica.ml:124-151,
1772-1774`) in full before editing.

```ocaml
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

`append_refusals : int array`'s size is already derived from `List.length append_refusal_kinds`,
so it grows automatically — no other change there.

Promote `for_test_append_refusals` to a real, production-facing accessor. Read its real, current
doc comment (`replica.mli`, "Diagnostics, not protocol... nothing in this module reads it") and
decide, against the real current code, whether to add a parallel non-test-prefixed accessor or
rename the existing one outright (an implementation-plan decision per the spec's own Decision 4).
Either way, the net effect must be: a real caller, not just a test, can read these counts. Update
the doc comment to describe the intended real use (a caller watching `eviction_blocked`'s count
grow, alongside `commit_number` failing to advance, as the real signal that materialization has
genuinely fallen behind).

Update `test/test_vsr_replica_recovery.ml`'s existing discrimination test (referenced in
`classify_append_refusal`'s own doc comment as pinning "the real exceptions those modules raise
land in the intended buckets") to add a fourth case proving a genuine `Eviction_blocked` refusal
from `File_storage` (constructed with a real `?may_evict` predicate that refuses) lands in this
new bucket — read that test's real, current structure first and match its own conventions.

- [ ] **Step 5: Run to verify pass**

Run: `dune clean && dune build && dune test --force`
Expected: all new tests `[OK]`, full suite otherwise unchanged.

- [ ] **Step 6: Commit**

```bash
git add lib/storage/file_storage.ml lib/storage/file_storage.mli lib/vsr/replica.ml lib/vsr/replica.mli test/test_file_storage.ml test/test_vsr_replica_recovery.ml
git commit -m "storage,vsr: File_storage.create gains ?may_evict, reusing Replica's existing refusal-classification machinery with a promoted, production-facing accessor -- part 2 of subtask 3.7"
```

---

### Task 5: Batch_commit range-based materialize drain (subtask 3.7, part 3 of 4)

**Files:**
- Modify: `lib/batch_commit/batch_commit.ml`, `lib/batch_commit/batch_commit.mli`
- Test: `test/test_batch_commit_materialize.ml` (extend)

**Interfaces:**
- Consumes: `Batch_commit`'s existing `materialize_sink`, `committed_batch_values`,
  `batch_of_value` (all real, current, unchanged by this task).
- Produces: `val materialize_up_to : Riptide_vsr.Replica.t -> materialize:materialize_sink ->
  through_commit_number:int -> unit`. Consumed by Task 6.

**Context, already confirmed by direct code reading:** `committed_batch_values`
(`lib/batch_commit/batch_commit.ml:99-102`) is `let committed_batch_values t = let all =
Riptide_vsr.Replica.entries t in let committed_count = Riptide_vsr.Replica.commit_number t in
List.filteri (fun i _ -> i < committed_count) all` — list position `i` (0-based) corresponds
directly to op-number `i+1`/commit position. `batch_of_value` (`:86-95`) decodes one `Value.value`
into `(string * write list) option`. `type write = { actor; causation; correlation; payload :
Value.value; merge_key : string option }` (`:3-8`). `type materialize_sink = { write :
merge_key:string -> Value.value -> unit }` (`:155` / `.mli:92-94`).

- [ ] **Step 1: Write the failing test**

`test/test_batch_commit_materialize.ml` — read the real, current file's helpers for building a
solo replica and a real `Materializer`-backed `materialize_sink` first, then add:

```ocaml
let test_materialize_up_to_drains_the_whole_committed_prefix () =
  Eio_main.run @@ fun env ->
  let dir = make_tmp_dir "riptide_materialize_up_to_test" in
  Fun.protect ~finally:(fun () -> rm_rf dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let replica =
    Replica.create ~my_id:1 ~replica_count:1 ~svc_limit:10 ~send:(fun ~to_:_ _ -> ())
      ~storage:(Replica.volatile_storage ())
  in
  Replica.for_test_set_view_number replica 1;
  (* Propose 3 batches under 3 distinct idempotency keys, each one write carrying merge_key "mk",
     using this file's own existing real write-construction and encode-into-batch-value helpers
     -- read the real, current file for the exact pattern before writing this. *)
  let materializer = (* this file's own existing real Materializer.Make(Last_write_wins)(File_kv_store) construction *) in
  let sink = { Batch_commit.write = (fun ~merge_key v -> Materializer.write materializer ~merge_key (decode v)) } in
  Batch_commit.materialize_up_to replica ~materialize:sink
    ~through_commit_number:(Replica.commit_number replica);
  Alcotest.(check bool) "the materializer converged to the join of all 3 writes" true
    (Materializer.read materializer ~merge_key:"mk" = (* expected joined Last_write_wins.t *) )

let test_materialize_up_to_is_idempotent () =
  (* Calling it twice with the same through_commit_number must be a safe no-op the second time --
     the whole point of Decision 2's restart-recovery design. *)
  Eio_main.run @@ fun env ->
  let dir = make_tmp_dir "riptide_materialize_up_to_idempotent_test" in
  Fun.protect ~finally:(fun () -> rm_rf dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let replica = (* same construction as above, one committed batch *) in
  let materializer = (* same real construction *) in
  let sink = (* same real sink *) in
  Batch_commit.materialize_up_to replica ~materialize:sink ~through_commit_number:1;
  let once = Materializer.read materializer ~merge_key:"mk" in
  Batch_commit.materialize_up_to replica ~materialize:sink ~through_commit_number:1;
  let twice = Materializer.read materializer ~merge_key:"mk" in
  Alcotest.(check bool) "re-materializing an already-covered range is a safe no-op" true (once = twice)

let test_materialize_up_to_respects_the_through_bound () =
  (* A commit_number bound lower than what's actually committed must not drain past it. *)
  Eio_main.run @@ fun env ->
  let dir = make_tmp_dir "riptide_materialize_up_to_bound_test" in
  Fun.protect ~finally:(fun () -> rm_rf dir) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let replica = (* construction with 2 committed batches under DIFFERENT merge_keys "mk1"/"mk2" *) in
  let materializer = (* real construction *) in
  let sink = (* real sink *) in
  Batch_commit.materialize_up_to replica ~materialize:sink ~through_commit_number:1;
  Alcotest.(check bool) "only the first batch's key materialized" true
    (Materializer.read materializer ~merge_key:"mk1" <> Last_write_wins.bottom);
  Alcotest.(check bool) "the second batch's key, past the bound, did not" true
    (Materializer.read materializer ~merge_key:"mk2" = Last_write_wins.bottom)
```

Read this file's real, current helpers (write construction, batch encoding, `Materializer`
construction, `Last_write_wins`'s real `bottom`/equality) before finalizing the exact test bodies
— this sketch shows the required properties, not a verbatim transcription of unfamiliar helper
names.

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i materialize_up_to`
Expected: compile failure — `materialize_up_to` doesn't exist yet.

- [ ] **Step 3: Implement**

`lib/batch_commit/batch_commit.ml` — add, near the existing `committed_batch_values`/
`committed_writes_for`:

```ocaml
let materialize_up_to (t : Riptide_vsr.Replica.t) ~(materialize : materialize_sink)
    ~(through_commit_number : int) : unit =
  let entries = Riptide_vsr.Replica.entries t in
  List.iteri
    (fun i v ->
      if i < through_commit_number then
        match batch_of_value v with
        | None -> ()
        | Some (_idempotency_key, writes) ->
          List.iter
            (fun w ->
              match w.merge_key with
              | None -> ()
              | Some k -> materialize.write ~merge_key:k w.payload)
            writes)
    entries

(* Task 6's own ?may_evict predicate needs to answer "did the write committed at this op-number
   opt into materialization at all" without re-implementing batch_of_value's own decode logic a
   second time outside this module. [entries] is 0-based by list position; op-number N is at
   list index N - 1 (matching committed_batch_values' own established i <-> op-number
   correspondence used throughout this file). Returns false for an op-number outside the log's
   current bounds or a malformed batch -- both cases mean nothing here is claiming a merge_key,
   which is the same as "never opted in" as far as ?may_evict cares. *)
let write_at_op_number_has_merge_key (t : Riptide_vsr.Replica.t) ~(op_number : int) : bool =
  match List.nth_opt (Riptide_vsr.Replica.entries t) (op_number - 1) with
  | None -> false
  | Some v -> (
    match batch_of_value v with
    | None -> false
    | Some (_idempotency_key, writes) -> List.exists (fun w -> Option.is_some w.merge_key) writes)
```

`lib/batch_commit/batch_commit.mli` — add `val materialize_up_to : Riptide_vsr.Replica.t ->
materialize:materialize_sink -> through_commit_number:int -> unit` with a real doc comment:
walks the committed log from its start through `through_commit_number` (inclusive, 0-based list
position vs 1-based op-number — state this precisely), materializing every write carrying a
`merge_key`, in commit order; safe to call repeatedly over an overlapping or fully-covered range
(a lattice join is idempotent); **does not track its own "last materialized" position** — the
caller (Task 6) owns any watermark it wants to avoid redundant re-walks, and this function's own
cost is `O(through_commit_number)` per call, a real, disclosed characteristic, not a hidden one.

Also add `val write_at_op_number_has_merge_key : Riptide_vsr.Replica.t -> op_number:int -> bool`
with a real doc comment: true iff the write committed at this 1-based op-number carries a
`merge_key`; false for an op-number that doesn't exist (yet, or ever) in the log or whose entry
fails to decode as a well-formed batch. This is Task 6's own `?may_evict` predicate's second half
(the first half — "at or below the current watermark" — is state Task 6 owns itself, not this
module).

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force`
Expected: all 3 new tests `[OK]`, full suite otherwise unchanged.

- [ ] **Step 5: Commit**

```bash
git add lib/batch_commit/batch_commit.ml lib/batch_commit/batch_commit.mli test/test_batch_commit_materialize.ml
git commit -m "batch_commit: materialize_up_to -- a range-based generalization of committed_writes_for, idempotent and restart-safe -- part 3 of subtask 3.7"
```

---

### Task 6: Wire the watermark end to end, and prove it closes the general case (subtask 3.7, part 4 of 4)

**Files:**
- Test: `test/test_lattice_materialize_crypto_scenarios.ml` (extend, reusing this file's own real
  5-replica adversarial harness conventions)

**Interfaces:**
- Consumes: `Riptide_vsr.Replica.create`'s `?on_commit_advanced` (Task 3), `File_storage.create`'s
  `?may_evict` and the promoted refusal-count accessor (Task 4), `Batch_commit.materialize_up_to`
  (Task 5).
- Produces: a real, working, tested closure of subtask 3.7's general case. No later task in this
  plan depends on this one's own new exports — this is the plan's last task.

**This is the task with the most genuine remaining design judgment — read the real, current code
before writing anything**, per this project's own established discipline. The pieces (Tasks 3-5)
are each real and tested in isolation; this task's job is wiring them together through a real
multi-replica scenario and proving the end-to-end property, without introducing anything into
production `lib/` code (there is still no `bin/` entrypoint in this repo — this wiring lives
entirely in the test harness, the shape any future real caller would follow, matching this plan's
own explicit non-goal).

- [ ] **Step 1: Build the wiring closure**

Read `test/test_lattice_materialize_crypto_scenarios.ml`'s real, current 5-replica adversarial
harness in full (`replica_count = 5` at `:296`, `replication_quorum`/`fault_config_for`/
`run_scenario` starting around `:296-360`, and its own per-replica `Materializer`/`File_kv_store`
construction pattern) before writing this task's own new scenario — reuse its conventions rather
than building a new harness.

For each replica in a fresh, real multi-replica cluster, build the watermark-tracking closure this
plan's Decision 2/3 describe, using Task 5's own `materialize_up_to` and
`write_at_op_number_has_merge_key`:

```ocaml
let watermark = ref 0 in
let on_commit_advanced ~old_commit:_ ~new_commit =
  Batch_commit.materialize_up_to replica ~materialize:sink ~through_commit_number:new_commit;
  watermark := new_commit
in
let may_evict ~op_number =
  op_number <= !watermark
  || not (Batch_commit.write_at_op_number_has_merge_key replica ~op_number)
in
```

Construct each replica in the cluster with both `~on_commit_advanced` and (via its `File_storage`)
`~may_evict` wired to its own instances of the above (not shared across replicas — each replica
has its own watermark, its own materializer, its own ring).

On construction, immediately call `Batch_commit.materialize_up_to replica ~materialize:sink
~through_commit_number:(Replica.commit_number replica)` once, before the cluster starts handling
any messages — this is Decision 2's restart-recovery mechanism; even though nothing in this
scenario actually restarts a replica mid-run, prove the mechanism itself works by asserting it's a
safe no-op on a fresh replica (`commit_number = 0`).

- [ ] **Step 2: Write the real, multi-replica proof scenario**

Write a real scenario proving the specific case subtask 3.7 has been open about since before this
whole line of work started: a genuine **follower** (not the primary, not an operator-driven manual
drain) whose ring would have evicted a committed, `merge_key`-carrying entry before it was ever
materialized — proven safe now, because (a) the follower's own `?on_commit_advanced` hook fires
automatically off `handle_message` processing a piggybacked commit (no explicit external call), and
(b) if materialization genuinely can't keep up, the `?may_evict` gate blocks the eviction via the
now-registered `Eviction_blocked` refusal rather than silently losing the entry.

Required assertions, matching this plan's own Review Focus:
1. The follower's ring genuinely evicts an old slot during the run (confirm via
   `File_storage.wal_read` on the evicted op-number returning `None` or the corrupted-looking
   value — prove eviction really happened, not that the test is vacuous).
2. The materializer's own `read` for that key still reflects the evicted entry's contribution,
   converged — proving the watermark genuinely protected it before eviction.
3. Interleave writes that never set `merge_key` into the same run; confirm none of them ever trip
   `?may_evict`/increment the `Eviction_blocked` count — the existing, disclosed boundary stays
   completely unaffected by the new gate, proven directly.
4. A genuine backlog case: temporarically disable/slow the materialize sink for one replica (e.g. a
   sink that raises or delays) so that replica's watermark falls behind; confirm (a) no data is
   lost — the write stays durably in the WAL and materializes once the backlog clears — and (b) the
   promoted refusal-count accessor from Task 4 genuinely rises during the backlog window.
5. Non-vacuity, matching this whole plan's own established discipline: temporarily disable this
   task's own `?on_commit_advanced` wiring (or construct a variant harness with it removed) and
   confirm the same scenario now genuinely loses the entry — proving the test has real power to
   catch the exact regression this task closes — then confirm it passes with the wiring in place.
6. **Restart recovery, matching this plan's own Review Focus item 3 explicitly.** Using
   `Cluster.run_on_file_storage`'s real `restart` callback (confirmed real from this file's own
   existing use elsewhere in the just-merged plan's own Task 9 work — read its actual signature,
   `?lose_superblock:bool -> int -> bool`, before writing this), restart one follower replica
   mid-scenario (after it has committed and materialized at least one `merge_key`-carrying write,
   but before the run ends): the restart discards its in-memory `Replica.t` and `watermark` ref
   entirely, but its durable `File_storage`/materializer `File_kv_store` directories survive.
   Reattach it with a fresh `Replica.t` over the same durable backend, wire the same
   `?on_commit_advanced`/`?may_evict` closures with a fresh `watermark := 0`, and perform this
   task's own construction-time `materialize_up_to ... ~through_commit_number:(commit_number
   replica)` call. Assert the restarted replica's materializer converges to the *exact same* value
   for that `merge_key` as a sibling replica that never restarted — proving restart recovery
   genuinely requires no new durable watermark state, not merely asserting that it doesn't.

- [ ] **Step 3: Run to verify pass, and run the whole suite repeatedly**

Run: `dune clean && dune build && dune test --force`, at least 3 times, confirming stability (this
task sits directly on top of Task 1's own determinism fix — if this new multi-replica test is
itself flaky, investigate whether it's hitting a genuinely new mechanism before concluding it's
done, rather than assuming Task 1 already covers it).

- [ ] **Step 4: Commit**

```bash
git add test/test_lattice_materialize_crypto_scenarios.ml
git commit -m "test: wire the general multi-replica ring-eviction watermark end to end, closing subtask 3.7"
```

---
