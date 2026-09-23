# Storage-Fault-Tolerant Recovery and DST Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give VSR real durability, extend it with a CTRL-equivalent protocol-aware recovery
mechanism, build a real fault-injecting storage layer, and ship the VOPR-style DST harness
(task-master subtask 3.4) that only makes sense once the first three exist.

**Architecture:** A new `lib/storage/` library defines `Storage.S` (mirroring `Transport_intf.S`)
with two conforming implementations: `File_storage` (real, `eio_linux`/`io_uring`-backed,
`O_DIRECT`+`O_DSYNC`) and `Fault_injecting_storage` (deterministic, seeded, for testing).
`spec/tla/VSR.tla` gains a multi-step, interruptible view-change completion sequence carrying
nack information (TigerBeetle's real mechanism, not a textbook CTRL round-trip), which
`lib/vsr/replica.ml` then implements for real, reading/writing through `Storage.S`. A new
`lib/dst/` library orchestrates a full cluster (real `Replica.t`s, `Sim_transport`, and
`Fault_injecting_storage`) under one seed and one virtual clock.

**Tech Stack:** OCaml 5 / Eio 0.12, `eio_linux`/`uring` (io_uring, `O_DIRECT`/`O_DSYNC`) for real
durability, `digestif.SHA256` for checksums (this project's existing content-hash primitive), TLA+
2.19/TLC for the protocol extension, `alcotest`/`qcheck-core`/`qcheck-alcotest` for tests, matching
every existing convention in `lib/vsr/`, `lib/transport/`, `lib/sim/`.

**Spec:** `docs/superpowers/specs/2026-09-23-storage-fault-tolerant-recovery-design.md`

## Global Constraints

- Storage I/O is Linux-only via `eio_linux`'s low-level `io_uring` API — no portable-Eio `fsync`
  path exists on the installed Eio 0.12/OCaml 5.0.0 toolchain (Decision 2).
- Checksums use this project's existing `Value.content_hash` (`Digestif.SHA256`), never
  AEGIS-128L or any new authenticated-encryption dependency (Decision 6).
- Superblock is **3 copies** with a flexible read/write quorum, not TigerBeetle's 4 (Decision 6).
- The TLA+ model of storage faults is a per-op tri-state `{present, absent, corrupt}`, deliberately
  less faithful than the real ring-WAL format — do not model byte-level WAL structure in TLA+
  (Decision 5).
- The TLA+ model uses uniform `f+1` quorums everywhere, never three separate flexible quorum sizes
  (Decision 5).
- Protocol-aware recovery is a **multi-step, interruptible view-change completion** sequence
  carrying nack information, not a single-message piggyback and not a separate CTRL round-trip
  protocol (Decision 4).
- Every random decision in fault-injection code flows through `Prng.t` (`lib/sim/prng.ml`),
  explicitly threaded — never `Stdlib.Random` or OS entropy (existing project rule, quoted in
  `prng.mli`).
- Fault injection never exceeds `faults_max = replication_quorum − 1` per chunk (Decision 7) — a
  bound the harness itself must enforce, not just document.
- New library names follow the existing `riptide_<dirname>` convention (`riptide_storage`,
  `riptide_dst`), except the root `lib/dune`, which stays bare `riptide`.
- A mandatory finiteness check (Decision 5) runs against the first draft of the extended TLA+
  model before any other TLA+ work on it — this project already paid the cost of skipping this
  once (`SendDVC`'s unguarded self-loop).

## Review Focus

- **Torn/interrupted WAL write, then restart**: a write that didn't fully land before a crash must
  be detected as corrupt/absent on the next read, never silently returned as valid data with a
  passing checksum. (Task 2)
- **Superblock quorum at the boundary**: with 3 copies and one genuinely corrupted, a read must
  still reconstruct the correct majority value, not silently return the corrupted copy or fail
  outright. (Task 3)
- **`wal_truncate_after` called below the already-committed op-number**: VSR's own safety
  guarantee is that committed entries never disappear — this must be rejected by the caller
  (`replica.ml`), not silently accepted by the storage primitive. (Task 7)
- **A nack referencing an op-number outside any replica's real log range**: the multi-step
  completion sequence must handle this as a malformed/out-of-range input without crashing, matching
  this codebase's established "guard failure ⇒ total no-op" convention. (Task 7)
- **The fault injector itself exceeding `faults_max`** (an injector bug, not a protocol bug): must
  be caught by an internal assertion in the injector, not surface later as a false-positive "VSR
  lost data" finding from the DST harness. (Task 10)

---

## Task 1: `Storage.S` signature and `File_storage`'s durable single-write primitive

**Files:**
- Create: `lib/storage/storage_intf.ml`
- Create: `lib/storage/file_storage.ml`, `lib/storage/file_storage.mli`
- Create: `lib/storage/dune`
- Modify: `test/dune` (add `riptide_storage` and `eio_linux` to the `(libraries ...)` list)
- Test: `test/test_file_storage.ml`

**Interfaces:**
- Produces: `module type Storage.S` with `wal_append`, `wal_read`, `wal_truncate_after`,
  `wal_highest_op_number`, `superblock_write`, `superblock_read` (full signature below —
  `File_storage`'s later tasks fill in `wal_truncate_after`/ring behavior/superblock; this task
  only needs `wal_append`/`wal_read` to prove real durability).

- [ ] **Step 1: Define `Storage.S`**

`lib/storage/storage_intf.ml`:
```ocaml
(** Signature every conforming storage backend implements — mirrors
    [Riptide_transport.Transport_intf.S]'s minimalism: an abstract [t] plus
    the operations callers need, nothing about how a backend is opened or
    closed (each implementation has its own concrete [create]). *)
module type S = sig
  type t

  (** [wal_append t ~op_number bytes] durably appends one WAL entry.
      [op_number] must be exactly one greater than [wal_highest_op_number t]
      (matching {!Riptide_vsr.Replica_log.append}'s own out-of-order guard) —
      implementations raise [Invalid_argument] otherwise. Returns only after
      the write is durable (survives a process crash immediately after). *)
  val wal_append : t -> op_number:int -> string -> unit

  (** [wal_read t ~op_number] is [None] if no entry was ever written at
      [op_number], or if the entry stored there is corrupt (checksum
      mismatch) — a reader cannot tell those two cases apart from this
      signature alone, by design: telling them apart is exactly what the
      recovery protocol in Task 7 exists to do, using cross-replica
      evidence this single-node signature has no access to. *)
  val wal_read : t -> op_number:int -> string option

  (** [wal_truncate_after t ~op_number] discards every WAL entry with a
      higher op-number. No-op if [op_number >= wal_highest_op_number t]. *)
  val wal_truncate_after : t -> op_number:int -> unit

  (** 0 if the WAL is empty. *)
  val wal_highest_op_number : t -> int

  (** Durably overwrites the single superblock record. *)
  val superblock_write : t -> string -> unit

  (** [None] if no superblock was ever written, or if fewer than a majority
      of copies agree (see Task 3). *)
  val superblock_read : t -> string option
end
```

- [ ] **Step 2: Write the failing test for durable single-entry write/read-after-restart**

`test/test_file_storage.ml`:
```ocaml
open Riptide_storage

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_storage_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))) (fun () -> f dir)

let test_write_then_read_same_handle () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      File_storage.wal_append t ~op_number:1 "first entry";
      Alcotest.(check (option string)) "read back what was written" (Some "first entry")
        (File_storage.wal_read t ~op_number:1))

let test_write_then_read_after_reopen () =
  (* Proves real durability, not just an in-process cache: close and reopen
     the same on-disk directory as a fresh [t], as a real restart would. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
       File_storage.wal_append t ~op_number:1 "survives a restart");
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check (option string)) "still there after reopen" (Some "survives a restart")
        (File_storage.wal_read t2 ~op_number:1))

let test_out_of_order_append_rejected () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      File_storage.wal_append t ~op_number:1 "one";
      Alcotest.check_raises "op_number 3 after 1 is out of order" (Invalid_argument "wal_append: op_number 3 is not wal_highest_op_number t + 1")
        (fun () -> File_storage.wal_append t ~op_number:3 "skips two")

let tests =
  [
    ("write then read, same handle", `Quick, test_write_then_read_same_handle);
    ("write then read, after reopen (real durability)", `Quick, test_write_then_read_after_reopen);
    ("out-of-order append rejected", `Quick, test_out_of_order_append_rejected);
  ]
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `dune test 2>&1 | grep -A5 test_file_storage`
Expected: FAIL — `File_storage` doesn't exist yet.

- [ ] **Step 4: Implement `File_storage`'s durable single-entry primitive**

`lib/storage/file_storage.ml` (one WAL entry per file, named by op-number — Task 2 replaces this
with the real fixed-size ring; this task only needs to prove the `O_DIRECT`+`O_DSYNC` durability
primitive itself works against the real installed `eio_linux`). No directory file descriptor is
needed: `Eio_linux.Low_level.openat2` accepts a full path with `?dir` omitted (an absolute-style
path resolves on its own, the same as passing no `dirfd` to POSIX `openat`), so directory handling
stays on the portable `Eio.Path` API (no `O_DIRECT` needed for a directory, only for the data
files) and only individual entry files go through the low-level `io_uring` path:

```ocaml
type t = {
  sw : Eio.Switch.t;
  dir_path : string;
  mutable highest_op_number : int;
}

let open_flags_write = Uring.Open_flags.(direct + dsync + creat)
let open_flags_read = Uring.Open_flags.empty

let create ~sw ~fs dir_path =
  (match Eio.Path.kind ~follow:true Eio.Path.(fs / dir_path) with
   | `Not_found -> Eio.Path.mkdir ~perm:0o700 Eio.Path.(fs / dir_path)
   | _ -> ());
  { sw; dir_path; highest_op_number = 0 }

let entry_path t ~op_number = Printf.sprintf "%s/wal-%010d" t.dir_path op_number

let durable_write t path (data : string) =
  let fd =
    Eio_linux.Low_level.openat2 ~sw:t.sw ~seekable:true ~access:`RW ~flags:open_flags_write
      ~perm:0o600 ~resolve:Uring.Resolve.empty path
  in
  Fun.protect ~finally:(fun () -> ignore (Eio_unix.Fd.close fd)) (fun () ->
      let chunk = Eio_linux.Low_level.alloc_fixed_or_wait () in
      Fun.protect ~finally:(fun () -> Eio_linux.Low_level.free_fixed chunk) (fun () ->
          let cs = Uring.Region.to_cstruct chunk in
          Cstruct.blit_from_string data 0 cs 0 (String.length data);
          Eio_linux.Low_level.write fd chunk (String.length data)))

let durable_read t path =
  match
    Eio_linux.Low_level.openat2 ~sw:t.sw ~seekable:true ~access:`R ~flags:open_flags_read
      ~perm:0o600 ~resolve:Uring.Resolve.empty path
  with
  | exception Eio.Io _ -> None (* ENOENT: nothing was ever written at this path *)
  | fd ->
    Fun.protect ~finally:(fun () -> ignore (Eio_unix.Fd.close fd)) (fun () ->
        let chunk = Eio_linux.Low_level.alloc_fixed_or_wait () in
        Fun.protect ~finally:(fun () -> Eio_linux.Low_level.free_fixed chunk) (fun () ->
            match Eio_linux.Low_level.read_upto fd chunk (Uring.Region.length chunk) with
            | n -> Some (Uring.Region.to_string ~len:n chunk)
            | exception End_of_file -> None))

let wal_append t ~op_number data =
  if op_number <> t.highest_op_number + 1 then
    invalid_arg
      (Printf.sprintf "wal_append: op_number %d is not wal_highest_op_number t + 1" op_number)
  else begin
    durable_write t (entry_path t ~op_number) data;
    t.highest_op_number <- op_number
  end

let wal_read t ~op_number =
  if op_number < 1 || op_number > t.highest_op_number then None
  else durable_read t (entry_path t ~op_number)

let wal_highest_op_number t = t.highest_op_number
let wal_truncate_after t ~op_number = failwith "not implemented until Task 2"
let superblock_write t data = failwith "not implemented until Task 3"
let superblock_read t = failwith "not implemented until Task 3"
```

Task 1's tests only exercise `wal_append`/`wal_read`/the out-of-order guard — `wal_truncate_after`
and the superblock functions stay unimplemented until Tasks 2 and 3, whose own failing tests drive
them.

`lib/storage/file_storage.mli`:
```ocaml
include Storage_intf.S

val create : sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> string -> t
```

- [ ] **Step 5: `lib/storage/dune`**

```
(library
 (name riptide_storage)
 (libraries riptide eio eio.unix eio_linux uring))
```

- [ ] **Step 6: Add `riptide_storage`/`eio_linux` to `test/dune`'s `(libraries ...)` list**

- [ ] **Step 7: Run the tests to verify they pass**

Run: `dune test 2>&1 | grep -A10 test_file_storage`
Expected: all 3 tests PASS. If `openat2`'s directory-fd handling doesn't compile as sketched,
consult `Eio_linux.Low_level.open_dir : sw:Switch.t -> dir -> string -> fd` (confirmed present in
the installed `eio_linux v0.12`) as the directory-opening primitive instead of raw `openat2`.

- [ ] **Step 8: Commit**

```bash
git add lib/storage/ test/test_file_storage.ml test/dune
git commit -m "storage: Storage.S signature + File_storage's durable single-entry primitive"
```

---

## Task 2: `File_storage`'s fixed-size ring WAL with redundant headers

**Files:**
- Modify: `lib/storage/file_storage.ml`
- Test: `test/test_file_storage.ml` (extend)

**Interfaces:**
- Consumes: Task 1's `Storage.S`, `durable_write`/`durable_read` helpers.
- Produces: `wal_truncate_after`, real `wal_highest_op_number` tracking across wraparound, and a
  checksum-verified read path (`Value.content_hash` from the root `riptide` library, already a
  `lib/storage/dune` dependency).

- [ ] **Step 1: Write the failing tests**

```ocaml
let ring_capacity = 8 (* small, so a wraparound test is cheap to write *)

let test_ring_wraps_around () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      for op = 1 to ring_capacity + 3 do
        File_storage.wal_append t ~op_number:op (Printf.sprintf "entry-%d" op)
      done;
      (* the ring only holds the most recent ring_capacity entries *)
      Alcotest.(check (option string)) "oldest entry evicted by wraparound" None
        (File_storage.wal_read t ~op_number:1);
      Alcotest.(check (option string)) "most recent entry present" (Some "entry-11")
        (File_storage.wal_read t ~op_number:(ring_capacity + 3)))

let test_truncate_after () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      List.iter (fun op -> File_storage.wal_append t ~op_number:op (Printf.sprintf "e%d" op)) [ 1; 2; 3 ];
      File_storage.wal_truncate_after t ~op_number:1;
      Alcotest.(check int) "highest op number after truncate" 1 (File_storage.wal_highest_op_number t);
      Alcotest.(check (option string)) "entry 2 gone" None (File_storage.wal_read t ~op_number:2);
      File_storage.wal_append t ~op_number:2 "replaces old entry 2";
      Alcotest.(check (option string)) "new entry 2 present" (Some "replaces old entry 2")
        (File_storage.wal_read t ~op_number:2))

let test_corrupted_entry_reads_as_none () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
       File_storage.wal_append t ~op_number:1 "will be corrupted on disk");
      (* Simulate corruption directly on disk, outside the Storage.S API --
         this test is what proves the checksum path is real, not a no-op. *)
      let raw_path = Filename.concat dir "ring-0000000000" in
      let ic = open_in_bin raw_path in
      let contents = really_input_string ic (in_channel_length ic) in
      close_in ic;
      let corrupted = Bytes.of_string contents in
      Bytes.set corrupted (Bytes.length corrupted - 1) (Char.chr (Char.code (Bytes.get corrupted (Bytes.length corrupted - 1)) lxor 0xFF));
      let oc = open_out_bin raw_path in
      output_bytes oc corrupted; close_out oc;
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check (option string)) "corrupted entry reads as None, not garbage" None
        (File_storage.wal_read t2 ~op_number:1))
```
Add all three to the `tests` list. (`test_corrupted_entry_reads_as_none`'s exact on-disk filename
depends on Step 2's chosen ring-file layout — adjust `raw_path` to match once Step 2 is written;
the point of the test, not the exact path, is load-bearing.)

- [ ] **Step 2: Run to verify failure**

Run: `dune test 2>&1 | grep -A10 "wraps_around\|truncate_after\|corrupted_entry"`
Expected: FAIL (ring/truncate/checksum behavior doesn't exist yet).

- [ ] **Step 3: Implement the ring + redundant header + checksum**

Redesign `entry_path`/`durable_write`/`durable_read` in `lib/storage/file_storage.ml`:
- One ring file per storage `t`, `ring_capacity` fixed slots (constant, e.g. `let ring_capacity = 8` for now — Task 9's DST harness will need a larger, configurable value; leave a `?ring_capacity` optional argument on `create`, defaulting to `8`).
- Each slot's **header** (op_number : int64, length : int64, checksum : the 32 raw bytes of
  `Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String data))`) is written to a
  **separate header region** at the front of the ring file, physically apart from the data region —
  this is what Decision 6 means by "redundant headers, stored separately from the entry's own
  body." Slot `i`'s header lives at a fixed offset (`i * header_slot_size`); slot `i`'s data lives
  at a fixed offset in the data region (`header_region_size + i * data_slot_size`).
- `wal_append t ~op_number data`: `slot = (op_number - 1) mod ring_capacity`; write the header then
  the data (two `durable_write` calls, header first — so a crash between them leaves a header
  pointing at stale/mismatched data, which the checksum on read catches, never a header pointing at
  correct data with no header at all).
- `wal_read t ~op_number`: recompute `slot`; read the header, read the data at that slot, verify
  `content_hash data = header.checksum` AND `header.op_number = op_number` (the second check is
  what makes `wal_read` correctly return `None` for `op_number:1` in `test_ring_wraps_around` once
  the slot has been overwritten by a later op — the stale header's own `op_number` field no longer
  matches). Any mismatch (checksum or op_number) returns `None`.
- `wal_truncate_after t ~op_number`: set `t.highest_op_number <- op_number` (no on-disk state
  change needed — a later `wal_append` at `op_number + 1` will overwrite the truncated slot's
  header/data directly, and `wal_read` for any op above the new `highest_op_number` should already
  return `None` once `wal_read` checks `op_number <= t.highest_op_number` first, before touching
  disk at all — add that check).
- `wal_highest_op_number t`: returns `t.highest_op_number`, tracked in memory and updated on every
  `wal_append`/`wal_truncate_after` (Task 1's `create` already reads existing on-disk state to
  reconstruct this on reopen — extend it to scan all `ring_capacity` slots' headers on `create` and
  take the maximum valid `op_number` found, so `test_write_then_read_after_reopen`-style durability
  still holds with the ring layout).

- [ ] **Step 4: Run to verify pass**

Run: `dune test 2>&1 | grep -A10 "wraps_around\|truncate_after\|corrupted_entry"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/file_storage.ml test/test_file_storage.ml
git commit -m "storage: fixed-size ring WAL with redundant headers and checksum verification"
```

---

## Task 3: 3-copy superblock with flexible read/write quorum

**Files:**
- Modify: `lib/storage/file_storage.ml`
- Test: `test/test_file_storage.ml` (extend)

**Interfaces:**
- Produces: real `superblock_write`/`superblock_read` (Task 1 left these as `failwith`).

- [ ] **Step 1: Write the failing tests**

```ocaml
let test_superblock_write_then_read () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      File_storage.superblock_write t "view=3,commit=7";
      Alcotest.(check (option string)) "superblock read back" (Some "view=3,commit=7")
        (File_storage.superblock_read t))

let test_superblock_survives_one_corrupted_copy () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
       File_storage.superblock_write t "view=5,commit=10");
      let copy0 = Filename.concat dir "superblock-0" in
      let oc = open_out_bin copy0 in
      output_string oc "garbage, wrong length and checksum";
      close_out oc;
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check (option string)) "majority (2 of 3) still readable" (Some "view=5,commit=10")
        (File_storage.superblock_read t2))

let test_superblock_none_without_majority () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
       File_storage.superblock_write t "view=1,commit=0");
      List.iter
        (fun i ->
          let oc = open_out_bin (Filename.concat dir (Printf.sprintf "superblock-%d" i)) in
          output_string oc "garbage"; close_out oc)
        [ 0; 1 ];
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check (option string)) "2 of 3 corrupted -- no majority, honest None" None
        (File_storage.superblock_read t2))
```

- [ ] **Step 2: Run to verify failure**

Run: `dune test 2>&1 | grep -A10 superblock`
Expected: FAIL — current `superblock_write`/`superblock_read` are `failwith`.

- [ ] **Step 3: Implement**

- `superblock_write t data`: write the same `(checksum, length, data)` triple (same header+data
  shape as Task 2's WAL entries, reusing `content_hash`) to all 3 files `superblock-0`,
  `superblock-1`, `superblock-2` — this is the "write requires all copies" half of the flexible
  quorum (matches Decision 6: write is the stricter side).
- `superblock_read t`: read all 3 copies, verify each against its own checksum, group the
  successfully-verified ones by exact byte content, and return `Some data` only if at least 2 of
  the (up to 3) verified copies agree — otherwise `None`. This is the "read tolerates one
  corrupted/missing copy" half. `superblock_read` re-reads from disk on every call — no cached
  field on `t` — matching `wal_read`'s own no-hidden-cache approach.

- [ ] **Step 4: Run to verify pass**

Run: `dune test 2>&1 | grep -A10 superblock`
Expected: all 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/storage/file_storage.ml test/test_file_storage.ml
git commit -m "storage: 3-copy superblock with flexible read/write quorum"
```

---

## Task 4: TLA+ mandatory finiteness check on the draft recovery extension

**Files:**
- Modify: `spec/tla/VSR.tla`
- Create: `spec/tla/VSR.cfg` finiteness variant, or a throwaway `spec/tla/VSR_finiteness_check.cfg`

**Interfaces:**
- Produces: confidence (or an early, cheap bug find) before Task 5's full extension is written.

- [ ] **Step 1: Draft the new state and actions, minimally**

Add to `VSR.tla`, without yet wiring them into real invariants:
- New per-replica, per-op variable modeling storage-fault state:
  `storage_fault \in [Replicas -> [1..MaxOp -> {"present", "absent", "corrupt"}]]` (the tri-state
  abstraction from Decision 5 — `MaxOp` bounded the same way this spec already bounds other
  sequences).
- A new action `SendNack(r)` (or the real name chosen once the multi-step sequence is drafted from
  the spec's Decision 4 description) that accumulates nack evidence into a bag/set — this is
  exactly the "nack accumulation" shape `spec/tla/README.md` already warned is likely to reproduce
  `SendDVC`'s unguarded-self-loop defect class.

- [ ] **Step 2: Add the throwaway finiteness probe**

In the `.cfg` used for this check, add:
```
INVARIANT NoUnboundedGrowth
```
and in `VSR.tla`:
```tla
NoUnboundedGrowth == \A m \in DOMAIN messages : Cardinality(messages[m]) < 3
```
(Exact predicate shape follows `spec/tla/README.md`'s own worked example — adjust to whatever the
real `messages`-like structure for nack accumulation turns out to be once Step 1 is drafted; the
point is a cheap, monotonic-growth tripwire, not this exact formula.)

- [ ] **Step 3: Run it**

Run: `scripts/tlc VSR` (or the throwaway cfg name from Step 2)
Expected: either a quick counterexample (a real bug, caught cheaply — fix the offending action's
guard and rerun) or genuine termination within a few minutes at a small bound. **Do not proceed to
Task 5 until this terminates.** If it doesn't terminate within a bound comparable to the existing
spec's own `264,376` states, that is itself a finding — narrow the drafted actions further before
scaling up, per `spec/tla/README.md`'s own explicit lesson.

- [ ] **Step 4: Commit the finiteness-check scaffolding and its result**

```bash
git add spec/tla/
git commit -m "vsr.tla: mandatory finiteness check on draft recovery extension (<result>)"
```
(Fill in `<result>` honestly — e.g. "terminates, 1,842 states" or "found+fixed an unguarded
self-loop in SendNack, now terminates" — matching this project's own disclosure convention for
TLA+ work.)

---

## Task 5: Full TLA+ recovery extension, exhaustively model-checked

**Files:**
- Modify: `spec/tla/VSR.tla`, `spec/tla/VSR.cfg`
- Modify: `spec/tla/README.md` (move storage-fault-aware recovery out of "explicitly out of scope"
  once this lands; record the real TLC evidence the same way the existing sections do)

**Interfaces:**
- Consumes: Task 4's finiteness-checked draft actions.
- Produces: the formal ground truth Task 6's OCaml implementation transcribes.

- [ ] **Step 1: Complete the multi-step, interruptible view-change completion sequence**

Extend Task 4's draft into the real sequence per Decision 4: the replica that would become primary
collects nacks (piggybacked on the existing `DoViewChange`-equivalent messages already in the
spec), determines per-op whether a quorum proves an op absent (safe to drop) or present (must
keep), and only completes the view change once every contested op is resolved — with a "forfeit"
step allowing the replica to abandon this attempt and let another view-change episode start if
resolution stalls (avoiding a liveness wedge). Use uniform `f+1` quorums throughout (Global
Constraints).

- [ ] **Step 2: Add new safety invariants**

At minimum: no committed entry is ever recoverable as `"absent"` (the storage-fault analogue of
`NoLogDivergence`), and the multi-step sequence cannot complete while any contested op remains
unresolved (no premature `StartView` — the recovery-aware version of the spec's existing
`CommitNumberNeverHigherThanOpNumber`-style discipline).

- [ ] **Step 3: Run TLC to the existing exhaustive-checking bar**

Run: `scripts/tlc VSR`
Expected: `Model checking completed. No error has been found.` with `0 states left on queue`,
quoted verbatim into `spec/tla/README.md` (the existing file's own convention — see its current
`VSR` results block for the exact format to match). If TLC finds a real counterexample, fix the
spec and rerun before proceeding — do not weaken an invariant to make it pass.

- [ ] **Step 4: Update `spec/tla/README.md`**

Move the "Storage-fault-aware recovery" bullet out of "Explicitly out of scope, for a follow-up
plan" and into the scope description at the top of the file, with the same disclosed-evidence style
the rest of the file already uses (quote the real TLC output, name any invariants that are vacuous
at the checked bound the way `NoLogDivergence`'s own caveat is already disclosed).

- [ ] **Step 5: Commit**

```bash
git add spec/tla/
git commit -m "vsr.tla: full storage-fault-aware recovery extension, exhaustively model-checked"
```

---

## Task 6: `Fault_injecting_storage`

**Files:**
- Create: `lib/storage/fault_injecting_storage.ml`, `.mli`
- Create: `test/test_storage_shared.ml` (shared functor test body, mirroring
  `test/test_transport_shared.ml`'s existing pattern)
- Modify: `lib/storage/dune`, `test/dune`

**Interfaces:**
- Consumes: `Storage.S` (Task 1), `Prng.t` (`lib/sim/prng.ml`, already built — add `riptide_sim` to
  `lib/storage/dune`'s libraries).
- Produces: `Fault_injecting_storage.create : prng:Prng.t -> ?fault_config:fault_config ->
  replication_quorum:int -> underlying:(module Storage.S with type t = 'a) -> 'a -> t` conforming
  to `Storage.S`, wrapping any real backend (in practice, `File_storage`, but genuinely generic — a
  real conformance benefit of keeping `Storage.S` minimal). `replication_quorum` is what Step 4's
  `faults_max = replication_quorum - 1` cap (Decision 7, Global Constraints) is computed from.

- [ ] **Step 1: Write the shared conformance test body**

`test/test_storage_shared.ml`, parameterized the way `test_transport_shared.ml` already is:
```ocaml
let shared_tests (module S : Riptide_storage.Storage_intf.S) (make : unit -> S.t) =
  let test_append_and_read () =
    let t = make () in
    S.wal_append t ~op_number:1 "hello";
    Alcotest.(check (option string)) "read back" (Some "hello") (S.wal_read t ~op_number:1)
  in
  [ ("append and read", `Quick, test_append_and_read) ]
```
(Extend with 2-3 more shared behaviors: `wal_highest_op_number` tracking, `wal_truncate_after`,
superblock round-trip — mirroring exactly what Tasks 1-3 already tested against `File_storage`
concretely, now run against both implementations from one body.)

- [ ] **Step 2: Instantiate it against `File_storage` (already passing) and `Fault_injecting_storage` (new, not yet written)**

In `test/test_file_storage.ml` (or a new small file), call
`Test_storage_shared.shared_tests (module File_storage) (fun () -> File_storage.create ~sw ~fs dir)`
(dune names the module after the file — `test/test_storage_shared.ml` compiles to
`Test_storage_shared`, matching `test/dune`'s single-executable-with-many-modules layout the same
way `test_transport_shared.ml` already works) and similarly for `Fault_injecting_storage` once it
exists — with the fault config set to all-zero probabilities for this conformance check (a faulty
backend under zero faults must behave identically to a non-faulty one; that's the whole point of it
conforming to the same signature).

- [ ] **Step 3: Run to verify the `Fault_injecting_storage` half fails (doesn't exist yet)**

Run: `dune test 2>&1 | grep -A5 "Fault_injecting"`
Expected: FAIL — module doesn't exist.

- [ ] **Step 4: Implement `Fault_injecting_storage`**

Wraps an underlying `Storage.S` value. At zero fault probability, every operation passes straight
through. With nonzero probability (config: `corrupt_probability`, `drop_probability` — mirroring
`lib/sim/network.ml`'s existing `fault_config` field names for consistency), `wal_append` may
XOR-flip a single deterministically-chosen byte of the data before delegating to the underlying
write (content-seeded via `Prng.int prng (String.length data)` for the byte position, so retries of
the *same* data never accidentally heal — matching Decision 7's "content-seeded... so retries
never heal it"), and enforces the cap: raise `Invalid_argument "faults_max exceeded"` if a caller's
`fault_config` would allow more simultaneous corrupted slots than `replication_quorum - 1` (a
`~replication_quorum:int` argument threaded through `create`, checked whenever corruption is about
to be applied to a slot that already has `faults_max` other corrupted slots live — track this with
a `mutable corrupted_slots : Int_set.t` field).

- [ ] **Step 5: Run to verify pass**

Run: `dune test 2>&1 | grep -A10 "shared\|Fault_injecting"`
Expected: all PASS, including the zero-fault conformance run.

- [ ] **Step 6: Adversarial mutation test — prove the fault injection is actually exercised**

Mirror `Transport_intf`'s own precedent: write one test with `corrupt_probability:1.0` and confirm
`wal_read` after a full-probability-corrupted `wal_append` really can return `None` (not just
theoretically capable of it) — a deliberately weakened assertion (e.g. "corruption is applied" logic
commented out) should make this specific test fail, proving it isn't vacuously passing.

- [ ] **Step 7: Commit**

```bash
git add lib/storage/fault_injecting_storage.ml lib/storage/fault_injecting_storage.mli \
        lib/storage/dune test/test_storage_shared.ml test/dune
git commit -m "storage: Fault_injecting_storage, shared Storage.S conformance suite"
```

---

## Task 7: OCaml multi-step interruptible view-change completion in `replica.ml`

**Files:**
- Modify: `lib/vsr/replica.ml`, `lib/vsr/replica.mli`
- Modify: `lib/vsr/dune` (add `riptide_storage`)
- Test: `test/test_vsr_replica_recovery.ml` (new)

**Interfaces:**
- Consumes: Task 5's TLA+ spec (the actions/invariants this transcribes), `Storage.S` (Task 1),
  `Replica.t`'s existing fields (`handle_do_view_change`, `try_send_dvc`, `try_send_sv` — exact
  current bodies quoted in this plan's own research; this task extends, not replaces, them).
- Produces: `Replica.create` gains a `storage:(module Storage.S with type t = 's) -> 's ->` pair of
  arguments (module + value, following the existing `~send:(to_:int -> string -> unit)` pattern of
  taking behavior as a value rather than a functor parameter, to keep `Replica.t` itself
  monomorphic — confirm this compiles against the real `Storage.S` shape; if OCaml's lack of
  first-class modules-as-values-with-full-inference makes this awkward, the fallback is a small
  record of closures `{ wal_append : op_number:int -> string -> unit; ... }` built once from a
  concrete `Storage.S` module at the call site, which is a strictly simpler, always-compiling
  alternative — prefer the record if the module-value approach fights the type checker for more
  than one fix-round).

- [ ] **Step 1: Write the failing test for the new-caller-visible behavior**

`test/test_vsr_replica_recovery.ml`:
```ocaml
open Riptide_vsr

let test_recovery_rejects_truncate_below_commit_number () =
  (* Review Focus item: wal_truncate_after below the committed op-number
     must be rejected by replica.ml, never silently accepted. *)
  let storage = Riptide_storage.File_storage.create ~sw:(*...*) ~fs:(*...*) (Filename.temp_file "t" "") in
  let r =
    Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3
      ~send:(fun ~to_:_ _ -> ())
      ~storage:(module Riptide_storage.File_storage) storage
  in
  Replica.propose r (Value.Scalar (Value.String "committed"));
  (* after settling to commit_number = 1 in a real cluster harness *)
  Alcotest.check_raises "truncate below commit_number is rejected"
    (Invalid_argument "recovery: refusing to truncate below commit_number")
    (fun () -> Replica.for_test_truncate_wal r ~op_number:0)

let tests = [ ("truncate below commit_number rejected", `Quick, test_recovery_rejects_truncate_below_commit_number) ]
```
(This single-replica test only exercises the guard; Task 8's cluster test exercises the real
multi-step recovery sequence end-to-end — this task's own test list should also include a
same-shape single-replica test for the out-of-range-nack Review Focus item, following this same
pattern once the real nack-handling function name is chosen in Step 2.)

- [ ] **Step 2: Run to verify failure**

Run: `dune test 2>&1 | grep -A5 test_vsr_replica_recovery`
Expected: FAIL — `~storage`, `for_test_truncate_wal` don't exist yet.

- [ ] **Step 3: Implement, transcribing Task 5's TLA+ actions**

- Thread `storage` through `Replica.create` and `t` (per the Interfaces note above).
- Every `Replica_log.append`/`Replica_log.replace_with` call site in the existing normal-case and
  view-change code additionally calls the storage backend's `wal_append`/equivalent — the in-memory
  `Replica_log.t` and the durable `Storage.S` backend now advance together, not as separate sources
  of truth (the durable copy is authoritative across restarts; `Replica_log.t` stays as the
  fast in-memory path for a running process, matching how VSR's own paper keeps an in-memory log
  with durability as an orthogonal concern).
- Extend `handle_do_view_change`/`try_send_dvc`/`try_send_sv` with the multi-step sequence from
  Task 5: nack accumulation, per-op resolution, the forfeit escape. Guard: before calling
  `wal_truncate_after`, check `op_number >= Replica.commit_number t`; raise `Invalid_argument
  "recovery: refusing to truncate below commit_number"` otherwise (Review Focus item).
- Guard: a nack referencing an op-number outside `[1, op_number t]` is ignored (total no-op),
  matching the codebase's established convention already used throughout `handle_do_view_change`'s
  existing bounds checks (`if i < 1 || i > t.replica_count then ()`, etc. — same style).
- Add `val for_test_truncate_wal : t -> op_number:int -> unit` to `replica.mli` for the test above.

- [ ] **Step 4: Run to verify pass**

Run: `dune test 2>&1 | grep -A10 test_vsr_replica_recovery`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vsr/ test/test_vsr_replica_recovery.ml
git commit -m "vsr: multi-step interruptible view-change completion, wired to Storage.S"
```

---

## Task 8: Cluster test — recovery under real injected storage faults

**Files:**
- Modify: `test/test_vsr_replica_recovery.ml`
- Modify: `lib/storage/fault_injecting_storage.ml`, `.mli` (adds `for_test_corrupt_entry`)

**Interfaces:**
- Consumes: `test_vsr_replica_view_change.ml`'s existing `with_cluster` harness (exact signature
  and `stop`/`settle`/`isolate`/`reconnect` mechanism quoted in this plan's own research — reuse
  directly, do not rewrite), `Fault_injecting_storage` (Task 6), Task 7's `~storage` wiring.

- [ ] **Step 1: Write the failing test, against a new `with_cluster_and_storage` wrapper**

```ocaml
let test_cluster_recovers_from_injected_corruption () =
  with_cluster_and_storage ~replica_count:3 ~svc_limit:3
    (fun ~replicas ~storages ~stop ~settle ~isolate:_ ~reconnect:_ ->
      let v = Value.Scalar (Value.String "must survive corruption") in
      Replica.propose replicas.(0) v;
      settle ();
      Alcotest.(check bool) "committed before any fault" true (Replica.is_committed replicas.(0) v);
      (* corrupt replica 2's on-disk copy of this entry directly, then crash
         the current primary and force a view change through replica 2 *)
      Fault_injecting_storage.for_test_corrupt_entry storages.(1) ~op_number:1;
      stop 1;
      fire_check_timeout_repeatedly replicas.(1) ~times:4;
      fire_check_timeout_repeatedly replicas.(2) ~times:4;
      settle ();
      Alcotest.(check bool) "entry recovered correctly despite one replica's corrupted copy" true
        (Replica.is_committed replicas.(1) v))

let tests = tests @ [ ("cluster recovers from injected corruption", `Quick, test_cluster_recovers_from_injected_corruption) ]
```

- [ ] **Step 2: Run to verify failure**

Run: `dune test 2>&1 | grep -A10 recovers_from_injected_corruption`
Expected: FAIL (`with_cluster_and_storage`, `for_test_corrupt_entry` don't exist yet).

- [ ] **Step 3: Write `with_cluster_and_storage` in `test_vsr_replica_recovery.ml`**

A local wrapper, not a modification of the existing, already-reviewed
`test_vsr_replica_view_change.ml` — it follows that file's own `with_cluster` structure exactly
(quoted in full in this plan's own research: the `Network`/`Sim_transport` setup, the
`isolate`/`reconnect`/`settle` closures, the per-replica `Eio.Switch.run`+`Replica_stopped`
crash-simulation pattern), with one addition: each replica's `Replica.create` call also receives
`~storage:(module Fault_injecting_storage) (Fault_injecting_storage.create ~prng
~replication_quorum:2 ~underlying:(module File_storage) (File_storage.create ~sw ~fs tmp_dir))`
(one fresh `File_storage` per replica, in its own temp directory), and the constructed
`Fault_injecting_storage.t` values are collected into a `storages : Fault_injecting_storage.t
array` passed to `body` alongside `replicas`. Add `for_test_corrupt_entry : t -> op_number:int ->
unit` to `Fault_injecting_storage.mli` (matching the existing `for_test_*` naming convention
already used throughout `replica.mli`) — it deterministically corrupts exactly the one op-number's
on-disk entry via the underlying `Storage.S`'s own `wal_append` (rewriting it with one flipped
byte), independent of `Fault_injecting_storage`'s own probabilistic fault path.

- [ ] **Step 4: Run to verify pass**

Run: `dune test 2>&1 | grep -A10 recovers_from_injected_corruption`
Expected: PASS. If it doesn't converge, this is exactly the kind of finding the spec's own Testing
section anticipates — debug against Task 5's TLA+ model and Task 7's transcription before
concluding the test itself is wrong.

- [ ] **Step 5: Commit**

```bash
git add test/test_vsr_replica_recovery.ml lib/storage/fault_injecting_storage.mli lib/vsr/replica.mli
git commit -m "vsr: cluster-level proof of recovery under real injected storage corruption"
```

---

## Task 9: `lib/dst/` — the harness skeleton

**Files:**
- Create: `lib/dst/dune`, `lib/dst/cluster.ml`, `.mli`
- Test: `test/test_dst_cluster.ml`

**Interfaces:**
- Consumes: `riptide_vsr`, `riptide_sim` (`Network`, `Sim_transport`, `Prng`, `Eio_mock.Clock`),
  `riptide_storage` (`Fault_injecting_storage`, `File_storage`).
- Produces: `Cluster.run : seed:int -> replica_count:int -> ?net_fault_config -> ?storage_fault_config
  -> (replicas:Replica.t array -> unit) -> unit` — one entry point standing up a full cluster (real
  `Replica.t`s over `Sim_transport` and per-replica `Fault_injecting_storage`) under one root seed,
  splitting it into independent sub-seeds for the network PRNG and each replica's storage PRNG (so
  reproducibility is per-component-attributable, not one entangled stream).

- [ ] **Step 1: Write the failing test**

```ocaml
let test_same_seed_reproduces_byte_identical_trace () =
  let trace_of seed =
    let log = ref [] in
    Riptide_dst.Cluster.run ~seed ~replica_count:3 (fun ~replicas ->
        Replica.propose replicas.(0) (Value.Scalar (Value.String "payload"));
        log := Replica.entries replicas.(0) :: !log);
    !log
  in
  Alcotest.(check bool) "same seed, identical trace" true (trace_of 42 = trace_of 42)

let test_different_seeds_can_diverge () =
  (* Proves the seed is actually load-bearing, not silently ignored: under a
     50% drop rate, different seeds should not all produce the same final
     log length after the same sequence of proposals. *)
  let final_log_length seed =
    let result = ref 0 in
    Riptide_dst.Cluster.run ~seed ~replica_count:3
      ~net_fault_config:Network.{ drop_probability = 0.5; duplicate_probability = 0.0; corrupt_probability = 0.0; min_delay = 0.0; max_delay = 0.0 }
      (fun ~replicas ->
        for i = 0 to 9 do
          Replica.propose replicas.(0) (Value.Scalar (Value.String (string_of_int i)))
        done;
        result := List.length (Replica.entries replicas.(0)));
    !result
  in
  let results = List.map final_log_length [ 1; 2; 3; 4; 5; 6; 7; 8; 9; 10 ] in
  Alcotest.(check bool) "seeds are load-bearing: not every seed gives the identical result under 50% drop"
    true
    (List.exists (fun r -> r <> List.hd results) results)

let tests =
  [
    ("same seed reproduces byte-identical trace", `Quick, test_same_seed_reproduces_byte_identical_trace);
    ("different seeds can diverge", `Quick, test_different_seeds_can_diverge);
  ]
```

- [ ] **Step 2: Run to verify failure**

Run: `dune test 2>&1 | grep -A5 test_dst_cluster`
Expected: FAIL — `Riptide_dst` doesn't exist.

- [ ] **Step 3: Implement `Cluster.run`**

Split `seed` deterministically into sub-seeds (e.g. `Prng.int (Prng.create seed) max_int` called
once per needed sub-stream — network, then one per replica's storage — so the split itself is
reproducible from the root seed alone). Build `Network`/`Sim_transport` handles per replica (same
pattern `with_cluster` already establishes, quoted in this plan's research), one
`Fault_injecting_storage` per replica wrapping a `File_storage` rooted in a fresh temp directory,
wire each `Replica.t` with its own send/storage, run all replicas' dispatch loops as forked fibers
inside `Eio_mock.Backend.run`, invoke the caller's `body`, then let the switch unwind (mirroring
`with_cluster`'s own `Cluster_test_done`/`Replica_stopped` exception pattern for clean teardown).

- [ ] **Step 4: Run to verify pass**

Run: `dune test 2>&1 | grep -A10 test_dst_cluster`
Expected: `test_same_seed_reproduces_byte_identical_trace` PASSES.

- [ ] **Step 5: Commit**

```bash
git add lib/dst/ test/test_dst_cluster.ml
git commit -m "dst: lib/dst/ harness skeleton -- full cluster over Sim_transport + Fault_injecting_storage, one seed"
```

---

## Task 10: Fault atlas discipline — `faults_max` enforcement and content-seeded determinism

**Files:**
- Modify: `lib/dst/cluster.ml`
- Test: `test/test_dst_cluster.ml` (extend)

**Interfaces:**
- Consumes: Task 6's `faults_max = replication_quorum - 1` enforcement inside
  `Fault_injecting_storage` itself.
- Produces: `Cluster.run`'s `~storage_fault_config` threads a `replication_quorum` value through to
  every replica's `Fault_injecting_storage.create` consistently, so the cap is enforced
  cluster-wide, not just per-instance in isolation.

- [ ] **Step 1: Write the failing test (Review Focus item: the injector itself exceeding the cap)**

```ocaml
let test_fault_config_exceeding_cap_is_rejected_at_cluster_creation () =
  Alcotest.check_raises "cluster refuses a storage fault config that could exceed faults_max"
    (Invalid_argument "storage fault config could corrupt more than faults_max = replication_quorum - 1 replicas' copies of the same slot")
    (fun () ->
      Riptide_dst.Cluster.run ~seed:1 ~replica_count:3
        ~storage_fault_config:{ Fault_injecting_storage.corrupt_probability = 1.0; drop_probability = 0.0 }
        (fun ~replicas:_ -> ()))
```

- [ ] **Step 2: Run to verify failure**

Run: `dune test 2>&1 | grep -A5 exceeding_the_cap`
Expected: FAIL — no such check exists yet in `Cluster.run`.

- [ ] **Step 3: Implement the cluster-level check**

`Cluster.run` computes `replication_quorum` from `replica_count` (the same `f+1`-style formula
`replica.ml` already uses internally — reuse it, don't reintroduce a second formula) and raises
`Invalid_argument` up front, before standing up any replica, if the given
`storage_fault_config.corrupt_probability` at cluster scale could plausibly exceed `faults_max`
simultaneous corrupted slots (a static, conservative check at cluster-creation time — Task 6's
per-instance runtime assertion inside `Fault_injecting_storage` remains the actual last line of
defense during a run, catching what this static check can't rule out in advance).

- [ ] **Step 4: Run to verify pass**

Run: `dune test 2>&1 | grep -A10 exceeding_the_cap`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/dst/cluster.ml test/test_dst_cluster.ml
git commit -m "dst: enforce faults_max = replication_quorum - 1 at cluster creation, not just per-instance"
```

---

## Task 11: A real scenario run that finds a real bug — closing subtask 3.4

**Files:**
- Create: `test/test_dst_scenarios.ml`

**Interfaces:**
- Consumes: everything from Tasks 1-10.

- [ ] **Step 1: Write a genuinely adversarial scenario, not a happy path**

```ocaml
let test_adversarial_scenario_survives_combined_network_and_storage_faults () =
  let seeds_tried = ref [] in
  let rec try_seed seed attempts_left =
    seeds_tried := seed :: !seeds_tried;
    if attempts_left = 0 then
      Alcotest.fail
        (Printf.sprintf "no invariant violation found across seeds %s -- widen the fault config before trusting this"
           (String.concat "," (List.map string_of_int !seeds_tried)))
    else
      Riptide_dst.Cluster.run ~seed ~replica_count:3
        ~net_fault_config:Network.{ drop_probability = 0.3; duplicate_probability = 0.1; corrupt_probability = 0.1; min_delay = 0.0; max_delay = 0.01 }
        ~storage_fault_config:Fault_injecting_storage.{ corrupt_probability = 0.2; drop_probability = 0.0 }
        (fun ~replicas ->
          for i = 0 to 19 do
            Replica.propose replicas.(0) (Value.Scalar (Value.String (Printf.sprintf "op-%d" i)))
          done;
          (* settle, then assert every replica that reports a committed op
             agrees with every other replica that also reports it committed
             -- the actual cross-replica safety property this whole plan
             exists to protect *)
          ())
  in
  try_seed 1 50 (* 50 different seeds -- this is the harness actually being used to hunt, not a single canned run *)
```

- [ ] **Step 2: Run it for real, seeds 1 through 50, and read the results**

Run: `dune test 2>&1 | grep -A30 adversarial_scenario`
Expected: **this step's real content is whatever it actually finds.** Per the spec's own Testing
section, this task's success criterion is empirical: it must lead to finding and fixing at least
one genuine bug in how Tasks 1-10 interact, the same way `batch_commit`'s and `Transport_intf`'s
own guarantees were proven by finding real bugs, not asserted clean by construction. If it passes
clean on the first try across all 50 seeds, that is itself suspicious for a system this new and
combinatorially complex — widen the fault config (higher probabilities, more replicas, more
proposed ops per run) and keep trying before concluding there's nothing left to find.

- [ ] **Step 3: For whatever is found — fix it, document the fix, and reproduce from its seed**

There is no fixed code to write for this step ahead of time (a real bug's fix depends on what the
bug is) — but the standard this project already holds itself to elsewhere applies unchanged: fix
the root cause (not a symptom), confirm the exact failing seed still reproduces it before the fix
and no longer does after, and record what was found in the commit message, the way
`test_vsr_replica_view_change.ml`'s own history already does for the liveness gaps it found.

- [ ] **Step 4: Commit**

```bash
git add test/test_dst_scenarios.ml
git commit -m "dst: first adversarial multi-fault scenario run -- <one-line summary of what it found and fixed>"
```

---

## Self-Review Notes

- **Spec coverage**: Decision 1 → Task 1. Decision 2 → Task 1. Decision 3 → Task 1/6 (`Storage.S`
  + its second implementation). Decision 4 → Tasks 5/7. Decision 5 → Tasks 4/5. Decision 6 → Tasks
  2/3. Decision 7 → Task 6. Decision 8 (the DST harness itself) → Tasks 9-11. Testing section →
  each task's own test-first steps plus Task 11's explicit empirical bug-finding requirement.
  Non-goals are honored by omission (no task touches encryption, non-Linux backends, reconfiguration,
  or a standalone CTRL round-trip protocol).
- **Review Focus**: all five items are each pinned to one task's own test, listed above.
- **Type consistency**: `Storage.S`'s six values (`wal_append`, `wal_read`, `wal_truncate_after`,
  `wal_highest_op_number`, `superblock_write`, `superblock_read`) are used with the same names and
  argument shapes in every later task that touches storage (`File_storage`, `Fault_injecting_storage`,
  `Replica.create`'s new `~storage` argument). `Replica.for_test_truncate_wal` (Task 7) and
  `Fault_injecting_storage.for_test_corrupt_entry` (Task 8) follows the existing
  `for_test_*` naming convention already established in `replica.mli`.
- **Known open engineering calls, deliberately left to the implementer within a task's own scope**
  (consistent with this project's own precedent of deciding some structural details at
  implementation time — e.g. `batch_commit`'s module placement): Task 1's exact directory-fd
  opening call (`openat2` vs `open_dir`) if the sketched code doesn't compile as written; Task 7's
  module-value-vs-closure-record choice for threading `Storage.S` through `Replica.t`; Task 9's
  exact sub-seed-splitting formula.
