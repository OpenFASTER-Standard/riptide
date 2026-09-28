# Mandatory Kv_store_intf.S Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Kv_store_intf.S`'s notion of directory ownership mandatory instead of optional, closing task-master subtask 4.8's remaining gap (`Materializer.create`'s own owner check) and the residual gap `Redaction_store.create`'s already-shipped fix left open (a bare `File_kv_store.create` with no `~owner` at all is invisible to every existing check).

**Architecture:** `Kv_store_intf.S` gains a required `owner : t -> string`; `File_kv_store.create`'s `?owner` becomes `owner` (required, no default); `Materializer.create` gains a required `~owner:string` and checks it against its `kv`'s own, mirroring `Redaction_store.create`'s existing check exactly. The unprotected ("no owner at all") state stops being constructible anywhere in the stack.

**Tech Stack:** OCaml 5, dune, Alcotest, Eio.

**Spec:** `docs/superpowers/specs/2026-09-28-mandatory-kv-store-ownership-design.md`

## Global Constraints

- No production `lib/` caller of `Materializer.Make(...).create` exists yet (no `bin/` entrypoint in this repo) — every call site touched by this plan is in `test/`.
- `File_kv_store` is `Kv_store_intf.S`'s only real implementer — no other module needs signature updates for the interface change itself.
- The whole repo (`dune build @all`) must compile after every task's final commit — this is a genuine breaking interface change with no way to migrate it incrementally across multiple always-green commits within one task, so each task's own file list is exactly what's needed to keep the repo green, no more, no less.
- Every retired test's commit message states plainly that the scenario it pinned is now a compile error, not merely that the test was deleted, per `CLAUDE.md`'s "no spec without running code" rule.

## Review Focus

- **`Materializer.create` called with the CORRECT owner must not raise** — every existing call site continuing to pass is implicit coverage, but the new task 2 test asserts it explicitly rather than leaving it to inference.
- **Every existing `File_kv_store.create`/`Materializer.create` call site in the whole repo, not just the ones a grep happens to catch first, must still compile** — a fresh `dune build @all` after each task's edits is the actual proof, not a manually-assembled list.
- **`Redaction_store.create`'s mismatch error message must stay byte-identical** for the "different owner" case once its comparison drops `Option` — `test_create_rejects_a_kv_tagged_for_a_different_owner` continuing to pass unmodified is the pin.
- **`File_kv_store.owner`'s return type change (`string option` → `string`) must be caught everywhere it's read**, not just at the two tests whose entire premise was "no owner" — `test_owner_reads_back_the_tag_used_at_construction` reads it too and needs its own assertion form updated from `option string` to plain `string`.
- **A retired test must be removed from its file's `tests` registration list, not just have its `let test_... = ...` body deleted** — an unbound identifier left in a `tests` list is a separate compile error from the one the retirement is meant to fix, easy to hit and easy to miss in the same edit.

---

### Task 1: Mandatory ownership on `Kv_store_intf.S`/`File_kv_store`, and `Redaction_store`'s matching simplification

**Files:**
- Modify: `lib/storage/kv_store_intf.ml`
- Modify: `lib/storage/file_kv_store.ml`
- Modify: `lib/storage/file_kv_store.mli`
- Modify: `lib/crypto/redaction_store.ml`
- Modify: `lib/crypto/redaction_store.mli`
- Modify: `test/test_file_kv_store.ml`
- Modify: `test/test_redaction.ml`
- Modify: `test/test_lattice_materialize_crypto_scenarios.ml`
- Test: all of the above (this task's own final step is a full-repo `dune build @all && dune test --force`, since a partial migration will not compile at all — there is no smaller unit to test in isolation)

**Interfaces:**
- Consumes: nothing from a later task.
- Produces: `Kv_store_intf.S`'s `val owner : t -> string`; `File_kv_store.create : sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> owner:string -> string -> t` (was `?owner:string`); `File_kv_store.owner : t -> string` (was `t -> string option`). Task 2 consumes both.

This task must land as one commit (or a tight sequence ending in one green state) — OCaml's whole-program type-checking means the repo cannot compile with `Kv_store_intf.S` strengthened but `Redaction_store.ml`'s existing `actual <> Some owner_tag` comparison still expecting an option, so there is no smaller always-green slice to stop at mid-task.

- [ ] **Step 1: Strengthen `Kv_store_intf.S`**

In `lib/storage/kv_store_intf.ml`, inside `module type S`, add:

```ocaml
val owner : t -> string
(** The tag this store was constructed with. Every implementer must have one; a backend with no
    real ownership/collision-risk concept can return a fixed placeholder. *)
```

- [ ] **Step 2: Make `File_kv_store`'s ownership mandatory**

In `lib/storage/file_kv_store.ml`:
- Change the `type t = { ...; owner : string option }` field (currently at line 84) to `owner : string`.
- `check_or_write_owner_marker ~fs ~dir_path owner` (currently `owner : string option`, with a `None -> ()` branch) loses that branch and its `match` entirely — it now always has a real `tag : string` to check or write. Its body becomes the current `Some tag -> (...)` arm's contents, unwrapped.
- `create ~sw ~fs ?owner dir_path` (currently optional) becomes `create ~sw ~fs ~owner dir_path` (required, no `?`).
- `let owner t = t.owner` (currently returning `string option`) is unchanged in body — its type now follows the record field's new type automatically.

In `lib/storage/file_kv_store.mli`:
- `val create : sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> ?owner:string -> string -> t` becomes `val create : sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> owner:string -> string -> t`.
- Update `create`'s doc comment: it currently documents `?owner`'s optionality and the `None` no-op behavior (search for "opt-out caller is not this function's responsibility") — rewrite that paragraph to state ownership is now mandatory and there is no opt-out; every `File_kv_store.t` has a declared owner.
- `owner`'s own doc comment (inherited from `Kv_store_intf.S` via `include Kv_store_intf.S` — no separate `.mli` declaration needed here) needs no edit in this file.

- [ ] **Step 3: Simplify `Redaction_store.create`'s check**

In `lib/crypto/redaction_store.ml`:
```ocaml
let create ~kv ~kek =
  let actual = Riptide_storage.File_kv_store.owner kv in
  if actual <> owner_tag then
    invalid_arg
      (Printf.sprintf "Redaction_store.create: kv is owned by %S, expected %S" actual owner_tag);
  { kv; kek }
```
(Drops the `Option.value ~default:"(none)"` — `actual` is now a plain `string`, and the error message's `%S actual` output for a real mismatch is byte-identical to before.)

In `lib/crypto/redaction_store.mli`: rewrite the residual-gap paragraph (search for "This still cannot protect a directory that a SECOND consumer") — it currently says a second consumer's own `File_kv_store.create` omitting `~owner` entirely defeats the guard. That state is no longer constructible after Step 2, so rewrite it to say the gap is closed: any `File_kv_store.create`, from any consumer, now requires an owner, so a directory can no longer be pointed at without one.

- [ ] **Step 4: Migrate `test_file_kv_store.ml`**

Add `~owner:"test"` to the 9 bare `File_kv_store.create` calls that are unrelated to the ownership tests themselves (the basic CRUD round-trips) — find them by attempting Step 6's build and fixing each reported error, or by searching this file for `File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir` with no `~owner` label.

Delete these two tests entirely — both their `let test_... = ...` definitions and their entries in this file's `tests` list — because the state each one proves is no longer constructible:
- `test_no_owner_supplied_is_unaffected` (its own comment: "Backward compatibility... omits `~owner`" — that call no longer compiles).
- `test_owner_is_none_when_no_tag_was_supplied` (asserts `File_kv_store.owner t = None`, impossible once `owner` returns a plain `string`).

Update `test_owner_reads_back_the_tag_used_at_construction`'s assertion from `Alcotest.(check (option string)) "owner reads back the construction-time tag" (Some "a-real-tag") (File_kv_store.owner t)` to `Alcotest.(check string) "owner reads back the construction-time tag" "a-real-tag" (File_kv_store.owner t)`.

- [ ] **Step 5: Migrate `test_redaction.ml` and `test_lattice_materialize_crypto_scenarios.ml`'s bare calls**

In `test_redaction.ml`: delete `test_create_rejects_an_untagged_kv` entirely (both its definition and its `tests`-list entry) — it constructs `File_kv_store.create ~sw ~fs dir` with no `~owner`, which no longer compiles, to prove `Redaction_store.create` rejects an untagged `kv`; that state can't be constructed anymore, so there's nothing left for it to prove. `test_create_rejects_a_kv_tagged_for_a_different_owner` (the other owner test in this file) already passes `~owner:"some-other-owner"` and needs no change — it stays exactly as-is, and its continued passing is Review Focus item 3's pin.

In `test_lattice_materialize_crypto_scenarios.ml`: delete `make_unowned_lenient_materializer` (its body constructs `File_kv_store.create ~sw ~fs dir` with no `~owner`) and the one test that uses it, `test_omitting_owner_on_the_materializer_side_alone_still_destroys_a_wrapped_dek` — both the definition and its `tests`-list entry — plus the ~30-line comment block immediately above that test explaining what it used to prove (search for "Narrowed by subtask 4.8, from what it used to demonstrate"). Do **not** touch `make_materializer` (a different helper, used by 13 other tests, which already passes `~owner:"materializer"` to `File_kv_store.create` and is Task 2's concern, not this task's) in this step.

- [ ] **Step 6: Build and run the whole suite**

Run: `dune clean && dune build @all && dune test --force`
Expected: clean build (every remaining compile error is a bare `File_kv_store.create` call Step 4 or 5 missed — fix and re-run until clean), full suite passes. Note the exact test count for Step 7's commit message.

- [ ] **Step 7: Commit**

```bash
git add lib/storage/kv_store_intf.ml lib/storage/file_kv_store.ml lib/storage/file_kv_store.mli \
  lib/crypto/redaction_store.ml lib/crypto/redaction_store.mli \
  test/test_file_kv_store.ml test/test_redaction.ml test/test_lattice_materialize_crypto_scenarios.ml
git commit -m "storage: Kv_store_intf.S ownership is now mandatory, not optional -- the unprotected state no longer compiles"
```

---

### Task 2: `Materializer.create` requires and checks its own `~owner`

**Files:**
- Modify: `lib/materialize/materializer.ml`
- Modify: `lib/materialize/materializer.mli`
- Modify: `test/test_materializer.ml`
- Modify: `test/test_batch_commit_materialize.ml`
- Modify: `test/test_dst_scenarios.ml`
- Modify: `test/test_lattice_materialize_crypto_scenarios.ml`
- Test: `test/test_materializer.ml` (new test), plus this task's own final full-repo `dune build @all && dune test --force`

**Interfaces:**
- Consumes: `File_kv_store.owner : t -> string` and `File_kv_store.create`'s mandatory `~owner` (Task 1).
- Produces: nothing a later task in this plan depends on — this is the plan's last task.

- [ ] **Step 1: Write the failing test**

In `test/test_materializer.ml`, add (matching this file's own existing `with_...`/`M.create` conventions — read the real, current file first):

```ocaml
let test_create_rejects_a_kv_tagged_for_a_different_owner () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"some-other-owner" dir in
      Alcotest.check_raises "a kv tagged for a different owner is rejected at construction"
        (Invalid_argument
           (Printf.sprintf "Materializer.create: kv is owned by %S, expected %S" "some-other-owner"
              "materializer"))
        (fun () -> ignore (M.create ~kv ~owner:"materializer" ~decode ~encode)))
```

(`decode`/`encode` reuse this file's own existing bindings for its already-established lattice type — read the real, current file's top before finalizing rather than inventing new ones.)

Also add `~owner:"materializer"` to this file's existing, already-passing `M.create ~kv ~decode ~encode` call (line 38 as of this plan's writing) — the same kv already has `~owner:"materializer"` from `File_kv_store.create`, so this asserts the matching-owner case succeeds (Review Focus item 1) as a side effect of the existing test continuing to pass.

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i materializer`
Expected: compile failure — `M.create`'s real signature doesn't yet accept `~owner`.

- [ ] **Step 3: Implement**

In `lib/materialize/materializer.ml`:
```ocaml
let create ~kv ~owner ~decode ~encode =
  let actual = KV.owner kv in
  if actual <> owner then
    invalid_arg
      (Printf.sprintf "Materializer.create: kv is owned by %S, expected %S" actual owner);
  { kv; decode; encode }
```

In `lib/materialize/materializer.mli`: add `owner:string ->` to `create`'s signature (`val create : kv:KV.t -> owner:string -> decode:(string -> L.t) -> encode:(L.t -> string) -> t`), and rewrite its doc comment's paragraph on why `Materializer` doesn't check ownership itself (search for "subtask 4.6's construction-time exclusive-ownership guard") — it currently explains why this function *can't* check; rewrite to state it now *does*, mirroring `Redaction_store.create`'s own doc pattern: `@raise Invalid_argument if [KV.owner kv <> owner]`, before `t` is constructed. Note explicitly (per the design spec's Decision 3) that unlike `Redaction_store.owner_tag`, there is no single exported constant here — different `Materializer` instances serve different `merge_key` namespaces, so the caller supplies whatever tag it built its own `kv` with.

- [ ] **Step 4: Run to verify pass, then migrate every other call site**

Run: `dune build 2>&1` — every remaining error names a `Materializer.create`/`M.create`/`Lww_materializer.create` call site missing `~owner`. Add `~owner:"materializer"` to each (all of them already build their `kv` with `~owner:"materializer"`, from Task 1's own migration, so this is the matching tag in every case):
- `test/test_batch_commit_materialize.ml`: 3 call sites (`M.create ~kv ...`, currently at lines 90, 162, 259 — confirm against the real, current file).
- `test/test_dst_scenarios.ml`: `make_lww_materializer`'s own `Lww_materializer.create ~kv:(...) ~decode ~encode` (currently ~line 1330).
- `test/test_lattice_materialize_crypto_scenarios.ml`: `make_materializer`'s own `M.create ~kv:(...) ~decode ~encode` (currently ~line 150) — this is the ONE fix that propagates to all 13 tests using that helper; do not touch individual call sites of `make_materializer` itself.

Run: `dune clean && dune build @all && dune test --force`
Expected: all pass, including the new test from Step 1. Confirm the test count grew by exactly 1 from Task 1's own final count (Step 6 of that task).

- [ ] **Step 5: Commit**

```bash
git add lib/materialize/materializer.ml lib/materialize/materializer.mli \
  test/test_materializer.ml test/test_batch_commit_materialize.ml test/test_dst_scenarios.ml \
  test/test_lattice_materialize_crypto_scenarios.ml
git commit -m "materialize: Materializer.create requires and checks ~owner, closing subtask 4.8's remaining half"
```

---

### Task 3: Update task-master

**Files:**
- Modify: `.taskmaster/tasks/tasks.json`

**Interfaces:**
- Consumes: the real commit SHAs from Tasks 1-2.
- Produces: nothing — this is the plan's final bookkeeping step.

- [ ] **Step 1: Mark subtask 4.8 done**

Per `CLAUDE.md`'s "task status is derived, never asserted" rule: update subtask 4.8's own `status` to `"done"` and its `evidence.commits` to the real SHAs from Task 1 and Task 2's commits (never a parent task's status by hand). Update its `description` to state both halves (`Redaction_store.create`, already done, and `Materializer.create`, done by this plan) are now closed, and that the residual "omitted owner entirely" gap named after `Redaction_store.create`'s own original fix is also closed by Task 1's `File_kv_store.create` change. If this makes task 4's own parent status mechanically derive to `"done"` (check its other subtasks), update that too — never independently of the derivation.

- [ ] **Step 2: Verify and commit**

Run: `python3 scripts/validate-tasks`
Expected: `ok`, with subtask 4.8's evidence commits verified as real ancestors of `HEAD`.

```bash
git add .taskmaster/tasks/tasks.json
git commit -m "tasks: mark subtask 4.8 done with evidence -- both halves closed, residual gap closed too"
```
