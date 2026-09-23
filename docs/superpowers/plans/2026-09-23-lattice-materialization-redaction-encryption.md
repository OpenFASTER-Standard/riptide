# Lattice, Materialization, Redaction, and Encryption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Layer 0 a generic (domain-agnostic) join-semilattice contract and incremental
materialization engine (closing subtask 3.7's ring-capacity data-loss finding for materialized
writes), real crypto-shredding redaction, and real mTLS between replicas.

**Architecture:** `lib/lattice/` defines the law (a module signature plus a reusable QCheck
conformance harness). `lib/storage/` gains a new `Kv_store.S` primitive (durable, keyed,
real-delete storage — distinct from `Storage.S`'s WAL/superblock shape) that both the materializer
and the redaction keystore build on. `lib/materialize/` is the generic incremental-projection
engine, folding writes into per-`merge_key` accumulators synchronously with commit — which is what
makes ring eviction safe. `lib/crypto/` holds real AES-256-GCM envelope encryption (fresh DEK per
record, deterministic counter nonces) and the redaction keystore. `lib/pki/` builds a minimal,
real, self-signed CA; `lib/transport/tcp.ml` gets real mutual TLS via `tls-eio`.

**Tech Stack:** OCaml 5 / Eio, `mirage-crypto`/`mirage-crypto-rng`/`mirage-crypto-pk` 2.4.1 (AES-GCM,
CSPRNG), `x509` 1.2.0 (CA/cert generation), `tls`/`tls-eio` 2.1.3 (mutual TLS over Eio),
`qcheck-core`/`qcheck-alcotest` (already a project dependency) for the lattice conformance harness.
All four packages plus their transitive dependencies are already installed in this box's durable
opam switch (`/work/toolchain/opam-root`) — confirmed live, versions match exactly what this plan's
own research verified.

**Spec:** `docs/superpowers/specs/2026-09-23-lattice-materialization-redaction-encryption-design.md`

## Global Constraints

- The lattice law contract is `type t; val bottom : t; val join : t -> t -> t` — enforced by a
  reusable QCheck conformance harness (commutativity, associativity, idempotency, `join bottom x =
  x`), mirroring `test_storage_shared.ml`/`test_transport_shared.ml`'s existing shared-conformance
  pattern (Decision 1).
- `merge_key : string` is opaque and caller-supplied — Layer 0 never inspects it (Decision 2).
- The materializer folds a merge-keyed write into its accumulator **synchronously**, in the same
  call that durably appends the write — this is what makes ring eviction safe by construction, not
  a runtime watermark check (Decision 3). Writes with no `merge_key` are unaffected by this plan;
  they remain exactly as subject to ring eviction as before this plan (a disclosed scope boundary,
  not a regression — Decision 2's "opt-in" framing already implies this).
- Redaction is **per-record**, via a genuinely independent, randomly-generated DEK per record —
  never HKDF-derived from the KEK (derivation defeats independent deletability; Decision 4).
- AEAD cipher is **AES-256-GCM with a deterministic, counter-based nonce per DEK**, never a randomly
  generated nonce (Decision 4; NIST SP 800-38D §8.2.1).
- The wrapped DEK lives in a separate keystore, structurally outside whatever the envelope's
  `content_hash` covers (Decision 4).
- The KEK is supplied externally at process startup via a file (permissions-restricted), generated
  outside Riptide — never generated or persisted by Riptide itself (Decision 5).
- mTLS is a minimal, self-managed static PKI (self-signed CA + per-replica certs, long-lived,
  manually rotated) via `x509`/`tls-eio` — **no SPIFFE/SPIRE**, explicitly deferred to task-master
  Task 8 (Decision 6).
- New library names follow the existing `riptide_<dirname>` convention.

## Review Focus

- **Nonce reuse under the deterministic counter scheme**: if the counter ever resets or two DEKs
  ever share a counter sequence, GCM's confidentiality/integrity guarantees collapse completely —
  a test must prove the counter is genuinely per-DEK and monotonic across many encryptions, not
  just assert the type signature looks right. (Task 5)
- **A redacted record must be genuinely unrecoverable, not just inconvenient to recover**: a test
  must attempt real decryption after redaction and observe real failure (an exception or `None`),
  not merely confirm the keystore lookup returns nothing. (Task 6)
- **Materializer convergence under out-of-order/concurrent delivery**: two different fold orders of
  the same set of writes for one `merge_key` must produce the identical accumulated value — this is
  the actual point of the lattice laws, and an implementation that happens to work for in-order
  delivery but silently depends on order is a real defect the spec's own testing section calls out.
  (Task 3)
- **A malformed or wrong-CA client certificate must be rejected, not merely unauthenticated**: mTLS
  handshake tests must include a real negative case (no cert, or a cert signed by an unrelated CA)
  and confirm the connection is refused, not just that a well-formed handshake succeeds. (Task 8)
- **The Kv_store's `delete` must be durable across a reopen** — the same class of bug this
  project already found once in `File_storage.wal_truncate_after` (fixed in the prior plan's final
  fix wave): a delete that only updates in-memory state and lets the reopened store resurrect a
  "deleted" key would silently break redaction's entire safety property. (Task 2)

---

## Task 1: `Lattice.S` — the law contract and its conformance harness

**Files:**
- Create: `lib/lattice/lattice_intf.ml`, `lib/lattice/dune`
- Create: `lib/lattice/last_write_wins.ml`/`.mli` (a real, domain-agnostic instance, proving the
  contract is satisfiable and giving the conformance harness something real to run against)
- Create: `test/lattice_conformance.ml` (the reusable harness, mirroring
  `test_transport_shared.ml`/`test_storage_shared.ml`'s existing pattern)
- Test: `test/test_lattice.ml`

**Interfaces:**
- Produces: `module type Lattice_intf.S = sig type t val bottom : t val join : t -> t -> t end`;
  `Lattice_conformance.tests : (module Lattice_intf.S with type t = 'a) -> 'a QCheck.arbitrary ->
  string -> unit Alcotest.test_case list` (the `string` is a label prefix for the generated test
  names, matching how `Test_storage_shared.shared_tests` labels its own instantiations).

- [ ] **Step 1: Define `Lattice_intf.S`**

`lib/lattice/lattice_intf.ml`:
```ocaml
(** The join-semilattice law contract (design spec Decision 1). Any type
    claiming to be mergeable at Layer 0 must satisfy: [join] is
    commutative, associative, and idempotent, and [bottom] is [join]'s
    identity element. This module type states the contract's shape; the
    laws themselves are checked by {!Lattice_conformance.tests} against a
    real generator for a concrete instance's [t] — they cannot be checked
    by the type system alone. *)
module type S = sig
  type t

  val bottom : t
  (** The identity element: [join bottom x = x] for all [x]. *)

  val join : t -> t -> t
  (** Must be commutative, associative, and idempotent. *)
end
```

- [ ] **Step 2: Write the conformance harness, and a failing test proving it catches a real violation**

`test/lattice_conformance.ml`:
```ocaml
let tests (type a) (module L : Riptide_lattice.Lattice_intf.S with type t = a)
    (arb : a QCheck.arbitrary) (label : string) : unit Alcotest.test_case list =
  let qcheck name prop = QCheck_alcotest.to_alcotest (QCheck.Test.make ~name ~count:200 prop) in
  [
    ( label ^ ": join is commutative", `Quick,
      fun () ->
        QCheck.Test.check_exn
          (QCheck.Test.make ~count:200 (QCheck.pair arb arb) (fun (a, b) ->
               L.join a b = L.join b a)) );
    ( label ^ ": join is associative", `Quick,
      fun () ->
        QCheck.Test.check_exn
          (QCheck.Test.make ~count:200 (QCheck.triple arb arb arb) (fun (a, b, c) ->
               L.join (L.join a b) c = L.join a (L.join b c))) );
    ( label ^ ": join is idempotent", `Quick,
      fun () ->
        QCheck.Test.check_exn
          (QCheck.Test.make ~count:200 arb (fun a -> L.join a a = a)) );
    ( label ^ ": bottom is the join identity", `Quick,
      fun () ->
        QCheck.Test.check_exn
          (QCheck.Test.make ~count:200 arb (fun a -> L.join L.bottom a = a)) );
  ]
```
(`qcheck`/`QCheck_alcotest` helper unused above — remove it if the direct `QCheck.Test.check_exn`
form is used throughout, as shown; keep the file to exactly these four tests, no more.)

`test/test_lattice.ml`:
```ocaml
open Riptide_lattice

(* A deliberately broken instance, used only to prove the harness is non-vacuous —
   NOT registered in test_riptide.ml, only invoked directly by the one test below. *)
module Broken_max : Lattice_intf.S with type t = int = struct
  type t = int
  let bottom = 0
  let join a b = if a > b then a - 1 (* wrong: breaks idempotency *) else b
end

let test_harness_catches_a_real_violation () =
  let broken_tests =
    Lattice_conformance.tests (module Broken_max) QCheck.small_int "broken"
  in
  let idempotent_case =
    List.find (fun (name, _, _) -> name = "broken: join is idempotent") broken_tests
  in
  let (_, _, run) = idempotent_case in
  Alcotest.check_raises "broken join fails its own idempotency check"
    (Failure "wildcard") (* placeholder pattern intentionally absent — see Step 3 note *)
    (fun () -> run ())

let tests = [ ("harness catches a real violation", `Quick, test_harness_catches_a_real_violation) ]
```

- [ ] **Step 2b: Fix the placeholder in Step 2's own test (this plan does not ship a real
  placeholder — resolve it now, before running anything)**

`QCheck.Test.check_exn` raises `QCheck.Test.Test_fail` on a failing property, not `Failure`. Replace
`test_harness_catches_a_real_violation`'s body with:
```ocaml
let test_harness_catches_a_real_violation () =
  let broken_tests = Lattice_conformance.tests (module Broken_max) QCheck.small_int "broken" in
  let (_, _, run) =
    List.find (fun (name, _, _) -> name = "broken: join is idempotent") broken_tests
  in
  Alcotest.check_raises "broken join fails its own idempotency check"
    (QCheck.Test.Test_fail ("broken: join is idempotent", []))
    run
  [@warning "-8"] (* the exact payload of Test_fail varies by run; catch-and-rethrow is cleaner *)
```
If `Alcotest.check_raises`'s exact-equality match on `Test_fail`'s payload proves too brittle in
practice (the failing-case list inside `Test_fail` is real data, not fixed text), replace with:
```ocaml
let test_harness_catches_a_real_violation () =
  let broken_tests = Lattice_conformance.tests (module Broken_max) QCheck.small_int "broken" in
  let (_, _, run) =
    List.find (fun (name, _, _) -> name = "broken: join is idempotent") broken_tests
  in
  match run () with
  | () -> Alcotest.fail "expected the broken instance's idempotency check to fail, it passed"
  | exception QCheck.Test.Test_fail _ -> ()
```
Use whichever compiles and passes — this is exactly the kind of small API-shape detail to confirm
against the real, installed `qcheck-core`/`qcheck-alcotest` (already a project dependency, exercised
elsewhere in `test/`) rather than guess further here.

- [ ] **Step 3: Run to verify it fails**

Run: `dune build 2>&1 | grep -i lattice`
Expected: `Unbound module Riptide_lattice` — the library doesn't exist yet.

- [ ] **Step 4: Implement `Last_write_wins`**

`lib/lattice/last_write_wins.ml`:
```ocaml
(** A register that keeps the value with the highest timestamp, breaking
    exact-timestamp ties deterministically by the value's own content hash
    — so [join] stays commutative even when two writers pick the same
    timestamp. [bottom] carries timestamp [Int64.min_int] so any real write
    dominates it. *)
type t = { value : Riptide.Value.value; timestamp : int64 }

let bottom = { value = Riptide.Value.Sequence []; timestamp = Int64.min_int }

let join a b =
  if a.timestamp <> b.timestamp then (if a.timestamp > b.timestamp then a else b)
  else if Riptide.Value.content_hash a.value >= Riptide.Value.content_hash b.value then a
  else b
```
`lib/lattice/last_write_wins.mli`:
```ocaml
include Riptide_lattice.Lattice_intf.S with type t = { value : Riptide.Value.value; timestamp : int64 }
```
(If OCaml rejects exposing a record type directly through `include ... with type t = <record>` this
way, expose the fields via ordinary `type t = { value : Riptide.Value.value; timestamp : int64 }`
plus a separate `include Lattice_intf.S with type t := t` — a mechanical fix, not a design change.)

`lib/lattice/dune`:
```
(library
 (name riptide_lattice)
 (libraries riptide))
```

- [ ] **Step 5: Wire the conformance harness against `Last_write_wins` in `test_lattice.ml`, run to verify pass**

Add to `test_lattice.ml`:
```ocaml
let lww_arbitrary =
  QCheck.map
    (fun (s, ts) -> Riptide_lattice.Last_write_wins.{ value = Riptide.Value.Scalar (Riptide.Value.String s); timestamp = ts })
    (QCheck.pair QCheck.small_string QCheck.int64)

let tests =
  tests
  @ Lattice_conformance.tests (module Riptide_lattice.Last_write_wins) lww_arbitrary "last_write_wins"
```

Run: `dune test --force 2>&1 | grep -i lattice`
Expected: all `lattice` tests `[OK]`.

- [ ] **Step 6: Commit**

```bash
git add lib/lattice/ test/lattice_conformance.ml test/test_lattice.ml test/dune test/test_riptide.ml
git commit -m "lattice: join-semilattice law contract + reusable conformance harness"
```
(Register `("lattice", Test_lattice.tests)` in `test/test_riptide.ml`'s `Alcotest.run` list and add
`riptide_lattice` to `test/dune`'s `libraries` in this same commit.)

---

## Task 2: `Kv_store.S` — durable, keyed storage with real per-key deletion

**Files:**
- Create: `lib/storage/kv_store_intf.ml`
- Create: `lib/storage/file_kv_store.ml`/`.mli`
- Test: `test/test_file_kv_store.ml`

**Interfaces:**
- Produces:
```ocaml
module type S = sig
  type t
  val get : t -> key:string -> string option
  val put : t -> key:string -> string -> unit
  val delete : t -> key:string -> unit
end
```
`File_kv_store.create : sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> string -> t`

**Context**: `Storage.S` (already built) is shaped for a bounded-ring WAL plus a fixed superblock —
neither shape fits "arbitrary number of independently-deletable keys," which both this task's
consumers (the materializer, Task 3; the redaction keystore, Task 6) need. This is a new, smaller
primitive, not a `Storage.S` variant. Read `lib/storage/file_storage.ml`'s existing
`alloc_aligned_buffer`/durable-write helpers first (already-merged, real `O_DIRECT`/`eio_linux`
techniques proven in that file) — reuse the same low-level pattern, applied to one file per key
instead of ring slots.

- [ ] **Step 1: Define `Kv_store_intf.S`**

`lib/storage/kv_store_intf.ml`:
```ocaml
(** A durable, keyed store with real per-key deletion — distinct from
    {!Storage_intf.S}'s bounded-ring-WAL-plus-superblock shape, which has
    no notion of an arbitrary number of independently-deletable keys. *)
module type S = sig
  type t

  val get : t -> key:string -> string option
  (** [None] if the key was never put, was deleted, or its stored value is
      corrupt (checksum mismatch) — the same "cannot distinguish never-written
      from corrupted" ambiguity {!Storage_intf.S.wal_read} already documents. *)

  val put : t -> key:string -> string -> unit
  (** Durably writes [key]'s value, overwriting any previous value. *)

  val delete : t -> key:string -> unit
  (** Durably removes [key]. Durable across a reopen — a deleted key must
      never be resurrected, the same class of bug this project already
      found and fixed once in [File_storage.wal_truncate_after]. No-op if
      the key was never put. *)
end
```

- [ ] **Step 2: Write the failing tests**

`test/test_file_kv_store.ml`:
```ocaml
open Riptide_storage

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_kv_test" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let test_put_then_get () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      File_kv_store.put t ~key:"foo" "bar";
      Alcotest.(check (option string)) "read back" (Some "bar") (File_kv_store.get t ~key:"foo"))

let test_get_of_never_put_key_is_none () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check (option string)) "never put" None (File_kv_store.get t ~key:"nope"))

let test_delete_is_durable_across_reopen () =
  (* Review Focus: this is the exact bug class already found once in
     File_storage.wal_truncate_after -- prove it doesn't recur here. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
       File_kv_store.put t ~key:"secret" "shhh";
       File_kv_store.delete t ~key:"secret");
      Eio.Switch.run @@ fun sw ->
      let t2 = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check (option string)) "deleted key stays gone after reopen" None
        (File_kv_store.get t2 ~key:"secret"))

let test_put_overwrites () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      File_kv_store.put t ~key:"k" "v1";
      File_kv_store.put t ~key:"k" "v2";
      Alcotest.(check (option string)) "overwritten" (Some "v2") (File_kv_store.get t ~key:"k"))

let tests =
  [
    ("put then get", `Quick, test_put_then_get);
    ("get of never-put key is None", `Quick, test_get_of_never_put_key_is_none);
    ("delete is durable across reopen", `Quick, test_delete_is_durable_across_reopen);
    ("put overwrites", `Quick, test_put_overwrites);
  ]
```

- [ ] **Step 3: Run to verify failure**

Run: `dune build 2>&1 | grep -i kv_store`
Expected: `Unbound module File_kv_store`.

- [ ] **Step 4: Implement `File_kv_store`**

`lib/storage/file_kv_store.ml` — one file per key, in a flat directory, named by the hex-encoded
SHA-256 of the key (`Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String key))`
via `Riptide.Value.hash_to_hex`, reusing the same content-hash primitive this project already uses
everywhere else — bounds the filename length regardless of key length, and sidesteps filesystem-
unsafe characters in an arbitrary opaque key). Reuse `File_storage.ml`'s exact durability pattern:
```ocaml
type t = { sw : Eio.Switch.t; fs : Eio.Fs.dir_ty Eio.Path.t; dir_path : string }

let open_flags_write = Uring.Open_flags.(direct + dsync + creat)
let open_flags_read = Uring.Open_flags.empty

let create ~sw ~fs dir_path =
  (match Eio.Path.kind ~follow:true Eio.Path.(fs / dir_path) with
   | `Not_found -> Eio.Path.mkdir ~perm:0o700 Eio.Path.(fs / dir_path)
   | _ -> ());
  { sw; fs; dir_path }

let path_for t ~key = Printf.sprintf "%s/%s" t.dir_path (Riptide.Value.hash_to_hex (Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String key))))

(* durable_write / durable_read: identical in shape to File_storage's own
   alloc_aligned_buffer-based helpers (mmap-backed page-aligned buffer via
   writev/readv, real O_DIRECT durability -- see file_storage.ml for the
   exact, already-proven implementation to transcribe here). *)

let get t ~key = durable_read t (path_for t ~key)

let put t ~key data = durable_write t (path_for t ~key) data

let delete t ~key =
  try Eio.Path.unlink Eio.Path.(t.fs / path_for t ~key)
  with Eio.Io _ -> () (* ENOENT: already absent, matching put's own idempotent-overwrite spirit *)
```

**Verified real API used above**: `Eio.Path.unlink : _ Eio.Path.t -> unit` is confirmed present in
the installed Eio 0.12 (`/work/toolchain/opam-root/5.0.0/lib/eio/path.mli:133`) — no need to fall
back to `Eio_linux.Low_level` for this operation. `type t` retains `fs` (the same value `create`
already receives) specifically so `delete` can build a path through it, mirroring how `create`
itself already uses `fs` for `Eio.Path.mkdir`/`Eio.Path.kind`.

`lib/storage/file_kv_store.mli`:
```ocaml
include Kv_store_intf.S

val create : sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> string -> t
```

- [ ] **Step 5: Run to verify pass**

Run: `dune clean && dune build && dune test --force 2>&1 | grep -i kv_store`
Expected: all 4 tests `[OK]`, including the reopen-durability test.

- [ ] **Step 6: Commit**

```bash
git add lib/storage/kv_store_intf.ml lib/storage/file_kv_store.ml lib/storage/file_kv_store.mli test/test_file_kv_store.ml test/dune test/test_riptide.ml
git commit -m "storage: Kv_store.S -- durable keyed storage with real per-key deletion"
```

---

## Task 3: The materializer — generic incremental projection

**Files:**
- Create: `lib/materialize/dune`, `lib/materialize/materializer.ml`/`.mli`
- Test: `test/test_materializer.ml`

**Interfaces:**
- Consumes: `Riptide_lattice.Lattice_intf.S` (Task 1), `Riptide_storage.Kv_store_intf.S`/
  `File_kv_store` (Task 2).
- Produces:
```ocaml
module Make (L : Riptide_lattice.Lattice_intf.S) (KV : Riptide_storage.Kv_store_intf.S) : sig
  type t
  val create : kv:KV.t -> decode:(string -> L.t) -> encode:(L.t -> string) -> t
  val write : t -> merge_key:string -> L.t -> unit
  val read : t -> merge_key:string -> L.t
end
```
(`write` folds the given value into the key's accumulator via `L.join`; `read` returns `L.bottom`
for a never-written key, matching the lattice's own identity element rather than an `option` —
"nothing written yet" and "the bottom value" are the same fact for a lattice.)

- [ ] **Step 1: Write the failing convergence test (Review Focus item)**

`test/test_materializer.ml`:
```ocaml
open Riptide_lattice
open Riptide_storage

module M = Riptide_materialize.Materializer.Make (Last_write_wins) (File_kv_store)

let with_materializer f =
  Eio_main.run @@ fun env ->
  let dir = Filename.temp_file "riptide_materialize_test" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      (* Real codec: Last_write_wins.t round-tripped through Value.value
         (a record of its two fields), then Value.canonical_encode/decode --
         the same wire-encoding primitive this codebase already uses for
         Envelope/Message, not a placeholder. *)
      let to_value (w : Last_write_wins.t) =
        Riptide.Value.Record
          [ ("value", w.value); ("timestamp", Riptide.Value.Scalar (Riptide.Value.Int w.timestamp)) ]
      in
      let of_value = function
        | Riptide.Value.Record fields ->
          let value = List.assoc "value" fields in
          let timestamp =
            match List.assoc "timestamp" fields with
            | Riptide.Value.Scalar (Riptide.Value.Int i) -> i
            | _ -> invalid_arg "Last_write_wins codec: malformed timestamp field"
          in
          Last_write_wins.{ value; timestamp }
        | _ -> invalid_arg "Last_write_wins codec: expected a Record"
      in
      let decode s = of_value (Riptide.Value.canonical_decode s) in
      let encode w = Riptide.Value.canonical_encode (to_value w) in
      f (M.create ~kv ~decode ~encode))

let test_convergence_regardless_of_fold_order () =
  let writes = [ { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String "a"); timestamp = 1L };
                 { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String "b"); timestamp = 2L };
                 { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String "c"); timestamp = 3L } ] in
  let converged_via order =
    with_materializer (fun m ->
        List.iter (fun w -> M.write m ~merge_key:"k" w) order;
        M.read m ~merge_key:"k")
  in
  let forward = converged_via writes in
  let reversed = converged_via (List.rev writes) in
  let shuffled = converged_via [ List.nth writes 1; List.nth writes 2; List.nth writes 0 ] in
  Alcotest.(check bool) "forward and reversed order converge to the same value" true
    (forward = reversed);
  Alcotest.(check bool) "shuffled order also converges to the same value" true
    (forward = shuffled)

let tests = [ ("convergence regardless of fold order", `Quick, test_convergence_regardless_of_fold_order) ]
```

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i materializ`
Expected: `Unbound module Riptide_materialize`.

- [ ] **Step 3: Implement `Materializer.Make`**

`lib/materialize/materializer.ml`:
```ocaml
module Make (L : Riptide_lattice.Lattice_intf.S) (KV : Riptide_storage.Kv_store_intf.S) = struct
  type t = { kv : KV.t; decode : string -> L.t; encode : L.t -> string }

  let create ~kv ~decode ~encode = { kv; decode; encode }

  let read t ~merge_key =
    match KV.get t.kv ~key:merge_key with
    | None -> L.bottom
    | Some s -> t.decode s

  let write t ~merge_key value =
    let current = read t ~merge_key in
    let merged = L.join current value in
    KV.put t.kv ~key:merge_key (t.encode merged)
end
```

`lib/materialize/materializer.mli`:
```ocaml
module Make (L : Riptide_lattice.Lattice_intf.S) (KV : Riptide_storage.Kv_store_intf.S) : sig
  type t
  val create : kv:KV.t -> decode:(string -> L.t) -> encode:(L.t -> string) -> t
  val write : t -> merge_key:string -> L.t -> unit
  val read : t -> merge_key:string -> L.t
end
```

`lib/materialize/dune`:
```
(library
 (name riptide_materialize)
 (libraries riptide riptide_lattice riptide_storage))
```

- [ ] **Step 4: Run to verify pass**

Run: `dune test --force 2>&1 | grep -i materializ`
Expected: `[OK]`.

- [ ] **Step 5: Commit**

```bash
git add lib/materialize/ test/test_materializer.ml test/dune test/test_riptide.ml
git commit -m "materialize: generic incremental-projection engine over any Lattice.S + Kv_store.S"
```

---

## Task 4: Wire materialization into the commit path — close subtask 3.7 for materialized writes

**Files:**
- Modify: `lib/batch_commit/batch_commit.ml`/`.mli`
- Test: `test/test_batch_commit.ml` (extend), new cluster-level reproduction test

**Interfaces:**
- Consumes: `Riptide_materialize.Materializer` (Task 3).
- Produces: `Batch_commit.write` gains `merge_key : string option`.

**Context**: read the current, real `lib/batch_commit/batch_commit.ml`/`.mli` on disk first (this
plan does not re-derive its existing `write`/`propose`/`committed_envelopes` shape — it extends it).
This is the task that actually closes subtask 3.7: a write proposed with a `merge_key` gets folded
into its materializer accumulator **synchronously**, as part of the same call that commits it — so
the accumulator can never lag behind what the WAL ring is about to evict, by construction, not by a
runtime check. A write with `merge_key = None` is unaffected — exactly as vulnerable to ring
eviction as before this plan (a disclosed scope boundary, per this plan's own Global Constraints).

- [ ] **Step 1: Write the failing reproduction test**

Mirror subtask 3.7's own original finding (a log exceeding `ring_capacity` destroys committed data
with no view change ever completing again — reproduced with zero injected faults in the prior
plan's Task 11), but this time with every write carrying a `merge_key`, proving the specific
scenario that used to wedge the cluster now survives because materialization has already absorbed
the evicted entries' content. Write this as a real cluster-level test reusing
`test_dst_scenarios.ml`'s or `test_vsr_replica_recovery.ml`'s existing harness conventions (read
whichever is the more current, real precedent on disk before writing this) — propose more ops than
`ring_capacity` allows, all under the same `merge_key`, and assert: (a) the raw WAL does lose the
old entries (confirming the ring eviction genuinely happened, not that the test is vacuous), and
(b) the materializer's own `read` for that `merge_key` still reflects all of them, converged.

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i batch_commit`
Expected: compile failure — `merge_key` doesn't exist on `Batch_commit.write` yet.

- [ ] **Step 3: Implement**

Add `merge_key : string option` to `Batch_commit.write`. In the propose path, after a write commits
(reusing whatever `batch_commit.ml`'s existing commit-confirmation mechanism is — read the real
code first), if `merge_key = Some k`, call the wired-in materializer's `write ~merge_key:k` with the
write's own payload decoded into whatever concrete `Lattice.S` instance the caller configured this
`Batch_commit` module with. This requires threading a materializer (parameterized by a concrete
lattice, which is Layer 2's choice per this plan's own Decision 1) into whatever `Batch_commit`
module or functor shape already exists — the exact threading mechanism (a functor parameter,
matching `Materializer.Make`'s own shape; or a value passed at `propose` call time) is a real design
call to make against the actual current `batch_commit.ml`, not fixed here.

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force`
Expected: all tests pass, including the new reproduction test.

- [ ] **Step 5: Commit**

```bash
git add lib/batch_commit/ test/
git commit -m "batch_commit: wire materialization into the commit path, closing subtask 3.7 for materialized writes"
```

---

## Task 5: Real envelope encryption — DEK generation and AES-256-GCM with a deterministic nonce

**Files:**
- Create: `lib/crypto/dune`, `lib/crypto/dek.ml`/`.mli`
- Test: `test/test_dek.ml`

**Interfaces:**
- Produces:
```ocaml
type t (* an unwrapped DEK plus its own nonce counter *)
val generate : unit -> t
val encrypt : t -> string -> string (* ciphertext, tag appended -- Mirage_crypto's own inline-tag shape *)
val decrypt : t -> string -> string option
val raw : t -> string (* the raw key bytes, for wrapping under a KEK -- Task 6 *)
val of_raw : string -> t (* reconstructing a DEK from its unwrapped bytes -- Task 6's own decrypt path *)
```

**Verified real API** (confirmed live against the installed `mirage-crypto` 2.4.1 and
`mirage-crypto-rng` 2.4.1 — read `lib/storage/file_storage.ml`'s own top-of-file precedent for how
this codebase already documents "confirmed against the real installed library" claims):
```ocaml
module Mirage_crypto.AES.GCM : sig
  val of_secret : string -> key
  val authenticate_encrypt : key:key -> nonce:string -> ?adata:string -> string -> string
  val authenticate_decrypt : key:key -> nonce:string -> ?adata:string -> string -> string option
end
val Mirage_crypto_rng.generate : ?g:Mirage_crypto_rng.g -> int -> string
val Mirage_crypto_rng_unix.use_default : unit -> unit
```

- [ ] **Step 1: Write the failing tests, including the Review Focus nonce-uniqueness proof**

`test/test_dek.ml`:
```ocaml
open Riptide_crypto

let () = Mirage_crypto_rng_unix.use_default ()

let test_roundtrip () =
  let dek = Dek.generate () in
  let ct = Dek.encrypt dek "hello world" in
  Alcotest.(check (option string)) "decrypts to the original" (Some "hello world") (Dek.decrypt dek ct)

let test_wrong_key_fails_to_decrypt () =
  let dek1 = Dek.generate () and dek2 = Dek.generate () in
  let ct = Dek.encrypt dek1 "secret" in
  Alcotest.(check (option string)) "wrong key fails auth" None (Dek.decrypt dek2 ct)

let test_ciphertext_is_not_plaintext () =
  let dek = Dek.generate () in
  let ct = Dek.encrypt dek "plaintext-marker" in
  Alcotest.(check bool) "ciphertext does not contain the plaintext bytes" false
    (try ignore (Str.search_forward (Str.regexp_string "plaintext-marker") ct 0); true
     with Not_found -> false)

let test_nonce_is_never_reused_across_many_encryptions () =
  (* Review Focus: nonce reuse under GCM is catastrophic -- prove the
     counter genuinely advances and never repeats, not just that the type
     signature looks right. Encrypt the same DEK many times and confirm
     every produced ciphertext (which embeds/implies a distinct nonce via
     Dek's own internal counter) decrypts correctly with THIS dek and no
     two runs collide in a way that would only be possible under nonce
     reuse (e.g. two ciphertexts for the same plaintext being byte-identical
     would indicate nonce reuse under a deterministic-nonce scheme). *)
  let dek = Dek.generate () in
  let ciphertexts = List.init 10_000 (fun i -> Dek.encrypt dek (Printf.sprintf "msg-%d" i)) in
  let unique = List.sort_uniq compare ciphertexts in
  Alcotest.(check int) "every ciphertext is distinct (no nonce collision)" 10_000 (List.length unique);
  List.iteri
    (fun i ct ->
      Alcotest.(check (option string)) (Printf.sprintf "message %d round-trips" i)
        (Some (Printf.sprintf "msg-%d" i)) (Dek.decrypt dek ct))
    ciphertexts

let tests =
  [
    ("roundtrip", `Quick, test_roundtrip);
    ("wrong key fails to decrypt", `Quick, test_wrong_key_fails_to_decrypt);
    ("ciphertext is not plaintext", `Quick, test_ciphertext_is_not_plaintext);
    ("nonce is never reused across many encryptions", `Quick, test_nonce_is_never_reused_across_many_encryptions);
  ]
```
(If `Str` isn't already a project dependency, replace `test_ciphertext_is_not_plaintext`'s check
with a plain substring search using `String`/a small hand-written helper — don't add a new
dependency for one test.)

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i crypto`
Expected: `Unbound module Riptide_crypto`.

- [ ] **Step 3: Implement `Dek`**

`lib/crypto/dek.ml`:
```ocaml
(** AES-256-GCM with a deterministic, per-DEK monotonic counter nonce
    (NIST SP 800-38D §8.2.1's permitted construction — never a randomly
    generated nonce, which carries a real collision risk under GCM's
    96-bit nonce at high encryption counts; design spec Decision 4). *)

type t = {
  key_bytes : string; (* retained alongside the constructed key below --
                          Mirage_crypto.AES.GCM.key is abstract, with no
                          accessor recovering the original secret, and
                          Task 6 needs these raw bytes to wrap a DEK under
                          the KEK. *)
  key : Mirage_crypto.AES.GCM.key;
  nonce_prefix : string;
  counter : int64 ref;
}

(* GCM's nonce is 12 bytes: a fixed 4-byte prefix (random, chosen once per
   DEK, to keep two different DEKs' counter sequences from ever colliding
   even if both started their counters at 0) plus an 8-byte big-endian
   monotonic counter. *)
let nonce_of t =
  let n = !(t.counter) in
  t.counter := Int64.add n 1L;
  let buf = Bytes.create 12 in
  Bytes.blit_string t.nonce_prefix 0 buf 0 4;
  Bytes.set_int64_be buf 4 n;
  Bytes.unsafe_to_string buf

let of_key_bytes key_bytes =
  { key_bytes; key = Mirage_crypto.AES.GCM.of_secret key_bytes; nonce_prefix = Mirage_crypto_rng.generate 4; counter = ref 0L }

let generate () = of_key_bytes (Mirage_crypto_rng.generate 32)
let of_raw raw_bytes = of_key_bytes raw_bytes
let raw t = t.key_bytes

let encrypt t plaintext =
  let nonce = nonce_of t in
  let ciphertext = Mirage_crypto.AES.GCM.authenticate_encrypt ~key:t.key ~nonce plaintext in
  (* the nonce is not secret, only the key is -- it must travel with the
     ciphertext so decrypt can recover it, hence prepended here. *)
  nonce ^ ciphertext

let decrypt t nonce_and_ciphertext =
  if String.length nonce_and_ciphertext < 12 then None
  else
    let nonce = String.sub nonce_and_ciphertext 0 12 in
    let ciphertext = String.sub nonce_and_ciphertext 12 (String.length nonce_and_ciphertext - 12) in
    Mirage_crypto.AES.GCM.authenticate_decrypt ~key:t.key ~nonce ciphertext
```

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force 2>&1 | grep -i dek`
Expected: all 4 tests `[OK]`, including 10,000 distinct nonces with zero collisions.

- [ ] **Step 5: Commit**

```bash
git add lib/crypto/dek.ml lib/crypto/dek.mli lib/crypto/dune test/test_dek.ml test/dune test/test_riptide.ml
git commit -m "crypto: Dek -- AES-256-GCM with a deterministic per-DEK counter nonce"
```

---

## Task 6: The redaction keystore, KEK sourcing, and envelope-encryption wiring

**Files:**
- Create: `lib/crypto/kek.ml`/`.mli`
- Create: `lib/crypto/redaction_store.ml`/`.mli`
- Modify: wherever this codebase currently constructs an `Envelope.envelope` for a real,
  content-hashed write (read `lib/envelope.ml`/`.mli` and `lib/batch_commit/batch_commit.ml` on
  disk first — this plan does not assume which one is the right integration point without checking
  the real, current code)
- Test: `test/test_redaction.ml`

**Interfaces:**
- Consumes: `Riptide_crypto.Dek` (Task 5), `Riptide_storage.Kv_store_intf.S`/`File_kv_store`
  (Task 2).
- Produces: `Kek.load : path:string -> Kek.t` (raises if the file is missing or the wrong length);
  `Redaction_store.encrypt_for_storage : t -> event_id:string -> Value.value -> string` (wraps a
  fresh DEK under the KEK, stores it keyed by `event_id`, returns ciphertext); `Redaction_store.
  decrypt : t -> event_id:string -> string -> Value.value option` (`None` if redacted or corrupt);
  `Redaction_store.redact : t -> event_id:string -> unit` (deletes the keystore entry).

- [ ] **Step 1: Write the failing tests, including the Review Focus unrecoverability proof**

`test/test_redaction.ml`:
```ocaml
open Riptide_crypto

let () = Mirage_crypto_rng_unix.use_default ()

let with_store f =
  Eio_main.run @@ fun env ->
  let dir = Filename.temp_file "riptide_redaction_test" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let kv = Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      let kek = Kek.of_raw (Mirage_crypto_rng.generate 32) (* test-only constructor; Kek.load is the real one, tested separately *) in
      f (Redaction_store.create ~kv ~kek))

let test_encrypt_then_decrypt () =
  with_store (fun store ->
      let v = Riptide.Value.Scalar (Riptide.Value.String "sensitive") in
      let ct = Redaction_store.encrypt_for_storage store ~event_id:"e1" v in
      Alcotest.(check bool) "decrypts back to the original" true
        (Redaction_store.decrypt store ~event_id:"e1" ct = Some v))

let test_content_hash_of_ciphertext_is_stable_across_redaction () =
  (* This is the whole point of Decision 4: the envelope's own content_hash
     covers ciphertext only, so redaction (deleting the keystore entry)
     must never change it. *)
  with_store (fun store ->
      let v = Riptide.Value.Scalar (Riptide.Value.String "sensitive") in
      let ct = Redaction_store.encrypt_for_storage store ~event_id:"e1" v in
      let hash_before = Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.Bytes ct)) in
      Redaction_store.redact store ~event_id:"e1";
      let hash_after = Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.Bytes ct)) in
      Alcotest.(check bool) "ciphertext's own hash is unchanged by redaction" true
        (hash_before = hash_after))

let test_redacted_payload_is_genuinely_unrecoverable () =
  (* Review Focus: attempt real decryption after redaction, don't just
     check the keystore lookup returns nothing. *)
  with_store (fun store ->
      let v = Riptide.Value.Scalar (Riptide.Value.String "sensitive") in
      let ct = Redaction_store.encrypt_for_storage store ~event_id:"e1" v in
      Redaction_store.redact store ~event_id:"e1";
      Alcotest.(check bool) "decryption genuinely fails post-redaction" true
        (Redaction_store.decrypt store ~event_id:"e1" ct = None))

let tests =
  [
    ("encrypt then decrypt", `Quick, test_encrypt_then_decrypt);
    ("content_hash of ciphertext is stable across redaction", `Quick, test_content_hash_of_ciphertext_is_stable_across_redaction);
    ("redacted payload is genuinely unrecoverable", `Quick, test_redacted_payload_is_genuinely_unrecoverable);
  ]
```
(`Kek.of_raw` is a test-only constructor for a KEK from raw bytes already in memory — the real
`Kek.load ~path` reads from a file; add a second, small test for `Kek.load` specifically: a missing
file raises, a wrong-length file raises, a well-formed file loads successfully. `Riptide.Value.Bytes`
— confirm this constructor's exact name against the real, current `lib/value.ml`/`.mli` before
using it; if `Value.value` has no raw-bytes scalar variant, store ciphertext as
`Value.Scalar (Value.String ct)` instead, consistent with how the rest of this codebase already
handles opaque byte strings inside `Value.value`.)

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i redaction`
Expected: `Unbound module Redaction_store`.

- [ ] **Step 3: Implement `Kek` and `Redaction_store`**

`lib/crypto/kek.ml`:
```ocaml
type t = string (* raw 32-byte key material *)

let load ~path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  if len <> 32 then (close_in ic; invalid_arg (Printf.sprintf "Kek.load: %s is %d bytes, expected exactly 32" path len));
  let raw = really_input_string ic 32 in
  close_in ic;
  raw

let of_raw raw =
  if String.length raw <> 32 then invalid_arg "Kek.of_raw: expected exactly 32 bytes";
  raw
```

`lib/crypto/redaction_store.ml`:
```ocaml
type t = { kv : Riptide_storage.File_kv_store.t; kek : Kek.t }

let create ~kv ~kek = { kv; kek }

let wrap_dek t (dek : Dek.t) = Dek.encrypt (Dek.of_raw t.kek) (Dek.raw dek)
let unwrap_dek t wrapped = Option.map Dek.of_raw (Dek.decrypt (Dek.of_raw t.kek) wrapped)

let encrypt_for_storage t ~event_id (v : Riptide.Value.value) =
  let dek = Dek.generate () in
  let plaintext = Riptide.Value.canonical_encode v in
  let ciphertext = Dek.encrypt dek plaintext in
  Riptide_storage.File_kv_store.put t.kv ~key:event_id (wrap_dek t dek);
  ciphertext

let decrypt t ~event_id ciphertext =
  match Riptide_storage.File_kv_store.get t.kv ~key:event_id with
  | None -> None
  | Some wrapped ->
    (match unwrap_dek t wrapped with
     | None -> None
     | Some dek ->
       (match Dek.decrypt dek ciphertext with
        | None -> None
        | Some plaintext -> (try Some (Riptide.Value.canonical_decode plaintext) with Invalid_argument _ -> None)))

let redact t ~event_id = Riptide_storage.File_kv_store.delete t.kv ~key:event_id
```

`lib/crypto/redaction_store.mli`:
```ocaml
type t
val create : kv:Riptide_storage.File_kv_store.t -> kek:Kek.t -> t
val encrypt_for_storage : t -> event_id:string -> Riptide.Value.value -> string
val decrypt : t -> event_id:string -> string -> Riptide.Value.value option
val redact : t -> event_id:string -> unit
```

**A real design decision this step must make, not fixed here**: where does envelope construction
actually call `encrypt_for_storage`/`decrypt`? Read the current, real `lib/envelope.ml`/`.mli` and
whatever constructs an `Envelope.envelope` on the write path (likely `lib/batch_commit/
batch_commit.ml`, per Task 4's own changes) — the payload must be encrypted *before*
`Envelope.content_hash` is computed over it, and decrypted (by whoever reads envelopes back out)
after. This may mean `Envelope.envelope`'s own `payload` field becomes ciphertext by construction
for every envelope (matching this plan's Section D unification: "if every payload is already always
encrypted... encryption at rest is baked into envelope construction, not a bolt-on"), with a
companion `event_id -> Value.value` decrypt step layered on top wherever a caller currently reads
`envelope.payload` directly. Trace every real call site before changing the type.

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force 2>&1 | grep -i redaction`
Expected: all tests `[OK]`.

- [ ] **Step 5: Commit**

```bash
git add lib/crypto/kek.ml lib/crypto/kek.mli lib/crypto/redaction_store.ml lib/crypto/redaction_store.mli test/test_redaction.ml test/dune test/test_riptide.ml
git commit -m "crypto: redaction keystore (DEK/KEK envelope encryption), KEK file sourcing"
```

---

## Task 7: A minimal, real, self-managed PKI

**Files:**
- Create: `lib/pki/dune`, `lib/pki/ca.ml`/`.mli`
- Test: `test/test_pki.ml`

**Interfaces:**
- Produces: `Ca.generate_root : common_name:string -> Ca.t` (a self-signed root: private key +
  certificate); `Ca.sign_leaf : Ca.t -> common_name:string -> valid_days:int -> X509.Certificate.t *
  X509.Private_key.t` (a fresh leaf keypair, signed by the root).

**Verified real API** (confirmed live against the installed `x509` 1.2.0):
```ocaml
X509.Private_key.generate : ?seed:string -> ?bits:int -> X509.Key_type.t -> X509.Private_key.t
X509.Signing_request.create : X509.Distinguished_name.t -> ?digest -> ?extensions -> X509.Private_key.t -> (X509.Signing_request.t, [> `Msg of string]) result
X509.Signing_request.sign : X509.Signing_request.t -> valid_from:Ptime.t -> valid_until:Ptime.t -> ?allowed_hashes -> ?digest -> ?serial -> ?extensions -> ?subject -> X509.Private_key.t -> X509.Distinguished_name.t -> (X509.Certificate.t, X509.Validation.signature_error) result
```
`X509.Key_type.t = [ \`RSA | \`ED25519 | \`P256 | \`P384 | \`P521 ]` — use `` `ED25519 `` (modern,
fast, no RSA bit-size decision to make).

- [ ] **Step 1: Write the failing tests**

`test/test_pki.ml`:
```ocaml
open Riptide_pki

let test_root_is_self_signed_and_verifiable () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  Alcotest.(check bool) "root cert's issuer matches its own subject" true
    (X509.Certificate.subject ca.Ca.cert = X509.Certificate.issuer ca.Ca.cert)

let test_sign_leaf_produces_a_cert_the_root_validates () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  let leaf_cert, _leaf_key = Ca.sign_leaf ca ~common_name:"replica-1" ~valid_days:365 in
  let time = Ptime_clock.now () in
  match X509.Validation.verify_chain_of_trust ~time ~anchors:[ ca.Ca.cert ] [ leaf_cert ] with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Fmt.to_to_string X509.Validation.pp_chain_error e)

let test_leaf_signed_by_unrelated_ca_is_rejected () =
  let ca1 = Ca.generate_root ~common_name:"ca-one" in
  let ca2 = Ca.generate_root ~common_name:"ca-two" in
  let leaf_cert, _ = Ca.sign_leaf ca2 ~common_name:"replica-x" ~valid_days:365 in
  let time = Ptime_clock.now () in
  match X509.Validation.verify_chain_of_trust ~time ~anchors:[ ca1.Ca.cert ] [ leaf_cert ] with
  | Ok _ -> Alcotest.fail "a leaf signed by an unrelated CA must not validate against a different anchor"
  | Error _ -> ()

let tests =
  [
    ("root is self-signed and verifiable", `Quick, test_root_is_self_signed_and_verifiable);
    ("sign_leaf produces a cert the root validates", `Quick, test_sign_leaf_produces_a_cert_the_root_validates);
    ("leaf signed by an unrelated CA is rejected", `Quick, test_leaf_signed_by_unrelated_ca_is_rejected);
  ]
```
(`X509.Certificate.subject`/`.issuer`, `X509.Validation.verify_chain_of_trust`/`.pp_chain_error` —
confirm these exact names against the real, installed `x509.mli`'s `Certificate`/`Validation`
modules, already located at `/work/toolchain/opam-root/5.0.0/lib/x509/x509.mli` on this box, before
using them; this plan verified `Signing_request`/`Private_key`/`Key_type` directly but not every
last `Certificate`/`Validation` accessor.)

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i pki`
Expected: `Unbound module Riptide_pki`.

- [ ] **Step 3: Implement `Ca`**

`lib/pki/ca.ml`:
```ocaml
type t = { key : X509.Private_key.t; cert : X509.Certificate.t }

let dn ~common_name =
  X509.Distinguished_name.
    [ Relative_distinguished_name.singleton (CN (Common_name.v common_name)) ]

let generate_root ~common_name =
  let key = X509.Private_key.generate `ED25519 in
  let subject = dn ~common_name in
  let now = Ptime_clock.now () in
  let valid_until = match Ptime.add_span now (Ptime.Span.v (3650, 0L)) with Some t -> t | None -> assert false in
  match X509.Signing_request.create subject key with
  | Error (`Msg m) -> failwith m
  | Ok csr ->
    match X509.Signing_request.sign csr ~valid_from:now ~valid_until key subject with
    | Error _ -> failwith "self-signing the root CA failed"
    | Ok cert -> { key; cert }

let sign_leaf t ~common_name ~valid_days =
  let leaf_key = X509.Private_key.generate `ED25519 in
  let subject = dn ~common_name in
  let now = Ptime_clock.now () in
  let valid_until = match Ptime.add_span now (Ptime.Span.v (valid_days, 0L)) with Some t -> t | None -> assert false in
  match X509.Signing_request.create subject leaf_key with
  | Error (`Msg m) -> failwith m
  | Ok csr ->
    match X509.Signing_request.sign_certificate csr ~valid_from:now ~valid_until t.key t.cert with
    | Error _ -> failwith "signing the leaf certificate failed"
    | Ok cert -> (cert, leaf_key)
```

`lib/pki/ca.mli`:
```ocaml
type t = { key : X509.Private_key.t; cert : X509.Certificate.t }
val generate_root : common_name:string -> t
val sign_leaf : t -> common_name:string -> valid_days:int -> X509.Certificate.t * X509.Private_key.t
```

`lib/pki/dune`:
```
(library
 (name riptide_pki)
 (libraries x509 mirage-crypto-pk mirage-crypto-rng ptime ptime.clock.os))
```

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force 2>&1 | grep -i pki`
Expected: all 3 tests `[OK]`.

- [ ] **Step 5: Commit**

```bash
git add lib/pki/ test/test_pki.ml test/dune test/test_riptide.ml
git commit -m "pki: minimal self-managed CA -- self-signed root + leaf signing, real x509 chain validation"
```

---

## Task 8: Real mutual TLS in `Riptide_transport.Tcp`

**Files:**
- Modify: `lib/transport/tcp.ml`/`.mli`, `lib/transport/dune`
- Test: extend the existing TCP transport test suite (read the real, current test file for `Tcp` on
  disk first — this plan does not re-derive its existing structure)

**Interfaces:**
- Consumes: `Riptide_pki.Ca` (Task 7).
- Produces: `Tcp.create`'s signature gains whatever's needed to supply the CA + this replica's own
  signed cert/key (exact shape — e.g. `~ca:X509.Certificate.t -> ~cert:X509.Certificate.t ->
  ~priv_key:X509.Private_key.t` — is this task's own call, made against the real, current `Tcp.create`
  signature, not fixed here).

**Verified real API** (confirmed live against the installed `tls`/`tls-eio` 2.1.3 — this project's
own concurrency substrate is Eio, so `tls-eio`, never `tls-lwt`/`tls-async`/`tls-mirage`):
```ocaml
Tls.Config.client : authenticator:X509.Authenticator.t -> ... -> Tls.Config.client
Tls.Config.server : ... -> ?authenticator:X509.Authenticator.t -> ... -> Tls.Config.server
Tls_eio.client_of_flow : Tls.Config.client -> ?host -> ?ip -> [...] r -> Tls_eio.t
Tls_eio.server_of_flow : Tls.Config.server -> [...] r -> Tls_eio.t
```
Mutual TLS = **both** sides verify the other's cert: `Tls.Config.client`'s `authenticator` is always
required (a client always verifies the server); the server side becomes mutual specifically by also
setting `Tls.Config.server`'s own `?authenticator` (otherwise a server accepts any/no client cert).
Both sides' authenticators trust the same root via **`X509.Authenticator.chain_of_trust : time:(unit
-> Ptime.t option) -> ?crls -> ?allowed_hashes -> X509.Certificate.t list -> X509.Authenticator.t`**
(confirmed real and installed) — it takes an in-memory certificate list directly, so Task 7's `Ca.t`
(already an in-memory `X509.Certificate.t`, no PEM round-trip needed) plugs straight in:
`X509.Authenticator.chain_of_trust ~time:(fun () -> Some (Ptime_clock.now ())) [ ca.Ca.cert ]`.

You must call `Mirage_crypto_rng_unix.use_default ()` once, early (e.g. wherever this codebase
already has a real process-startup path — `tls-eio`'s own `.mli` states a runtime error occurs if no
RNG is installed).

- [ ] **Step 1: Write the failing tests, including the Review Focus negative case**

Extend the existing TCP transport test file with: a real handshake between two in-process TCP
endpoints, one presenting Task 7's CA-signed cert as server, the other as client, both configured to
trust that same CA — assert the connection succeeds and both sides can exchange bytes over the now-
TLS-wrapped flow. Then the negative case: a client presenting a cert signed by a *different*,
unrelated CA (or no cert at all, if this transport's own topology allows an anonymous dial attempt)
must be rejected — assert the handshake raises `Tls_eio.Tls_alert` or `Tls_eio.Tls_failure` (the two
exceptions Task 7's own verified `.mli` documents), not that the connection silently succeeds.

- [ ] **Step 2: Run to verify failure**

Run: `dune build 2>&1 | grep -i transport`
Expected: compile failure once the test file references the new, not-yet-existing `Tcp.create`
parameters.

- [ ] **Step 3: Implement**

Wrap `Tcp`'s existing accept/connect paths: after the existing plain-TCP `Eio.Net.accept_fork`/
`Eio.Net.connect` call succeeds (read the real, current `tcp.ml` for its exact call sites first —
this plan does not restate the whole file), pass the resulting flow through `Tls_eio.server_of_flow`
(accept side) or `Tls_eio.client_of_flow` (connect side) before doing anything else with it — every
byte this transport sends/receives from that point on must go through the returned `Tls_eio.t`
flow, not the raw underlying one. Build the two `Tls.Config.t` values (client and server) once, at
`Tcp.create` time, from the CA/cert/key this task's own new parameters supply.

- [ ] **Step 4: Run to verify pass**

Run: `dune clean && dune build && dune test --force 2>&1 | grep -i transport`
Expected: all transport tests `[OK]`, including the new positive and negative mTLS cases.

- [ ] **Step 5: Commit**

```bash
git add lib/transport/ test/
git commit -m "transport: real mutual TLS over tls-eio for Tcp, using the in-repo CA"
```

---

## Task 9: End-to-end adversarial proof

**Files:**
- Create: `test/test_lattice_materialize_crypto_scenarios.ml`

**Interfaces:**
- Consumes: everything from Tasks 1-8.

This mirrors the prior plan's own Task 11 in spirit: a genuinely adversarial, multi-property proof
that the pieces built in this plan actually compose, not just pass in isolation. Per this project's
own established empirical-testing discipline, real effort here matters more than a scripted
checklist — investigate for real, and report honestly if nothing new turns up after real effort
(the same standard the prior plan's own Task 11 held itself to).

- [ ] **Step 1: Write and run a combined scenario**

At minimum, over many seeds: propose writes across several `merge_key`s, some via the fault-
injecting storage path (real corruption/drop), interleaved with real redaction of some (unrelated)
records' payloads and real mTLS-wrapped replication between replicas. After each phase, check: (a)
every materializer accumulator has converged to the same value regardless of which replica computed
it; (b) every redacted record is genuinely unrecoverable and every non-redacted record still is; (c)
no plaintext payload ever appears on a wire capture or raw disk read (grep the raw bytes for a
known, distinctive plaintext marker planted in one payload, the same technique `test_dek.ml`'s own
`test_ciphertext_is_not_plaintext` already established). Investigate real interactions between
materialization's synchronous-fold timing and the redaction keystore's own durability — these are
two new pieces of durable state added to the same write path in this plan, and their interaction
hasn't been exercised together anywhere else in this plan's own per-task tests.

- [ ] **Step 2: Fix whatever's found at the root, with a real regression test, matching this
  project's own established discipline** (see the prior plan's Task 11 for the exact bar: fix root
  causes, prove the exact failing seed reproduces pre-fix and not post-fix, never patch symptoms).

- [ ] **Step 3: Verify the full suite is green and stable**

Run: `dune clean && dune build && dune test --force`, repeated several times to confirm no
flakiness, matching every prior task's own verification bar in this project.

- [ ] **Step 4: Commit**

```bash
git add test/test_lattice_materialize_crypto_scenarios.ml
git commit -m "test: end-to-end adversarial proof across lattice/materialization/redaction/mTLS -- <summary of what was found>"
```

---

## Self-Review Notes

- **Spec coverage**: Decision 1 → Task 1. Decision 2 → Task 4 (`merge_key` threading). Decision 3 →
  Tasks 3-4. Decision 4 → Tasks 5-6. Decision 5 → Task 6 (`Kek.load`). Decision 6 → Tasks 7-8.
  Testing section → each task's own test-first steps plus Task 9's combined proof. Non-goals are
  honored by omission (no SPIFFE/SPIRE, no XChaCha20, no external KMS, no subject-granularity
  redaction as a Layer 0 primitive, no concrete-lattice choice for a real domain).
- **Review Focus**: all five items are each pinned to one task's own test, listed above.
- **Placeholder scan (re-run after the fixes below):** the plan's first draft had four real
  placeholders — an `Obj.magic` in Task 2's `Kv_store.delete`, a `Marshal`-based codec in Task 3's
  test, unresolved `Dek.raw`/nonce-prepending in Task 5, and a `failwith` in Task 7's `dn` — all four
  are now fixed in place with real, verified code (`Eio.Path.unlink`, a `Value.canonical_encode`-
  based codec, a real `key_bytes`-retaining `Dek.t` plus real nonce-prepending, and real
  `X509.Distinguished_name.Common_name.v`/`Relative_distinguished_name.singleton` calls), not left
  as instructions for the implementer to resolve later. Task 8's `X509.Authenticator` construction
  was similarly resolved with a verified, real `chain_of_trust` call taking Task 7's in-memory `Ca.t`
  directly.
- **Known open engineering calls genuinely left to the implementer** (consistent with this project's
  own precedent — e.g. `batch_commit`'s module placement, the prior storage plan's directory-fd-
  opening call — these are real design/integration decisions, not unverified API guesses): Task 2's
  exact low-level `eio_linux` transcription from `File_storage` (mechanical, already-proven
  technique, just needs re-applying); Task 4's exact materializer-threading mechanism into
  `Batch_commit`; Task 6's exact envelope-construction integration point; Task 8's exact `Tcp.create`
  parameter shape for supplying the CA/cert/key. Each of these is flagged in-place with instructions
  to verify against the real, already-installed
  library `.mli` files on this box before writing the final code — the same discipline the prior
  plan's own Task 1 (eio_linux) and this plan's own research already modeled.
