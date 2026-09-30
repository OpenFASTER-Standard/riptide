open Riptide_lattice
open Riptide_storage

module M = Riptide_materialize.Materializer.Make (Last_write_wins) (File_kv_store)

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_materialize_test" "" in
  Unix.unlink dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

(* Real codec: Last_write_wins.t round-tripped through Value.value
   (a record of its two fields), then Value.canonical_encode/decode --
   the same wire-encoding primitive this codebase already uses for
   Envelope/Message, not a placeholder. *)
let to_value (w : Last_write_wins.t) =
  Riptide.Value.Record
    [ ("value", w.value); ("timestamp", Riptide.Value.Scalar (Riptide.Value.Int w.timestamp)) ]

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

let decode s = of_value (Riptide.Value.canonical_decode s)
let encode w = Riptide.Value.canonical_encode (to_value w)

let with_materializer f =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      (* [~owner:"materializer"] on every real materializer-backing store in this repo: [M.create]
         below now requires [kv]'s own tag (as {!File_kv_store.owner} reports it) to match its
         [~owner] argument exactly, or construction raises. *)
      let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" dir in
      f (M.create ~kv ~owner:"materializer" ~decode ~encode))

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
  (* Check that all orderings converge to the same value *)
  Alcotest.(check bool) "forward and reversed order converge to the same value" true
    (forward = reversed);
  Alcotest.(check bool) "shuffled order also converges to the same value" true
    (forward = shuffled);
  (* Check that the converged value equals the expected result: timestamp 3, value "c" *)
  let expected = { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String "c"); timestamp = 3L } in
  Alcotest.(check bool) "converges to the expected LWW value (highest timestamp wins)" true
    (forward = expected)

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

(* The property that distinguishes THIS task's check from {!Riptide_crypto.Redaction_store.create}'s:
   the expected owner is a caller-supplied parameter, not one fixed project-wide constant --
   different [Materializer] instances serve different [merge_key] namespaces backed by different
   directories. Proven here with an owner tag no other test or real call site in this repo uses
   ("some-other-namespace" rather than "materializer"), on both sides, so a mutation that hardcoded
   the one string every current call site happens to use (e.g. [if actual <> "materializer" then])
   would make THIS test fail while leaving it silent everywhere else. Asserted positively, not just
   "did not raise": the resulting materializer is exercised with a real write-then-read round trip,
   so the check is that the thing genuinely works, not merely that construction was silent. *)
let test_create_accepts_a_kv_tagged_for_a_matching_caller_supplied_owner () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"some-other-namespace" dir in
      let m = M.create ~kv ~owner:"some-other-namespace" ~decode ~encode in
      let w = { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String "x"); timestamp = 1L } in
      M.write m ~merge_key:"k" w;
      Alcotest.(check bool) "a materializer built with a matching caller-supplied owner is usable" true
        (M.read m ~merge_key:"k" = w))

(* ---------------------------------------------------------------------------------------------
   Task 20: per-[merge_key] serialization. Both tests below need a lattice where every value
   folded in stays independently observable, so a lost update is directly visible as a missing
   element -- {!Last_write_wins} above cannot show this, since its [join] keeps exactly one
   winner and would make a lost update indistinguishable from an ordinary overwrite. [G_set] is
   copied from {!Riptide_lattice.Lattice_intf.S}'s own [test_lattice_materialize_crypto_scenarios]
   (a grow-only set of strings, [join] = union) for exactly this reason -- see that file's own
   comment for the full argument.
   --------------------------------------------------------------------------------------------- *)

module G_set : sig
  include Riptide_lattice.Lattice_intf.S

  val of_list : string list -> t
  val elements : t -> string list
  val to_value : t -> Riptide.Value.value
  val of_value : Riptide.Value.value -> t
end = struct
  type t = string list (* sorted, duplicate-free -- the canonical form [join] maintains *)

  let norm l = List.sort_uniq String.compare l
  let bottom = []
  let join a b = norm (a @ b)
  let of_list = norm
  let elements t = t

  let to_value t =
    Riptide.Value.Sequence (List.map (fun s -> Riptide.Value.Scalar (Riptide.Value.String s)) t)

  let of_value = function
    | Riptide.Value.Sequence items ->
      norm
        (List.map
           (function
             | Riptide.Value.Scalar (Riptide.Value.String s) -> s
             | _ -> invalid_arg "G_set.of_value: expected a Sequence of String scalars")
           items)
    | _ -> invalid_arg "G_set.of_value: expected a Sequence"
end

let g_set_decode s = G_set.of_value (Riptide.Value.canonical_decode s)
let g_set_encode g = Riptide.Value.canonical_encode (G_set.to_value g)

module GM = Riptide_materialize.Materializer.Make (G_set) (File_kv_store)

(* Real concurrent fibers over a real, on-disk [File_kv_store] -- [Eio.Fiber.all] schedules all
   [n] [GM.write] calls concurrently, and each one performs real io_uring [get]/[put] I/O
   ([File_kv_store.get]/[put], via [Eio_linux.Low_level]) that genuinely yields to other fibers
   mid-call, the same interleaving the audit's own reproduction relied on -- this is not a
   simulated race. *)
let test_concurrent_writers_to_one_merge_key_lose_no_updates () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" dir in
      let m = GM.create ~kv ~owner:"materializer" ~decode:g_set_decode ~encode:g_set_encode in
      let n = 16 in
      Eio.Fiber.all
        (List.init n (fun i () ->
             GM.write m ~merge_key:"shared" (G_set.of_list [ Printf.sprintf "writer-%d" i ])));
      let result = G_set.elements (GM.read m ~merge_key:"shared") in
      Alcotest.(check int) "all 16 elements present, not just 1" n (List.length result))

(* A minimal in-memory {!Riptide_storage.Kv_store_intf.S} used ONLY by the test below, to prove
   different [merge_key]s are not accidentally serialized against a single global lock. Real
   [File_kv_store] I/O always eventually completes, so it cannot demonstrate a NEGATIVE ("this
   call did not wait for that other one") -- this store's [get] can be told to suspend
   indefinitely for one specific key via {!block}/{!release}, using a real [Eio.Condition] (not a
   sleep/timing guess), so the test can deterministically hold one [merge_key]'s [write] mid-flight
   while checking whether a DIFFERENT [merge_key]'s [write] is still able to complete.

   No mutex guards [blocked]/[tbl]: same single-domain cooperative-scheduling argument as
   {!Aligned_buffer_pool}'s own doc comment -- [List.mem]/[Hashtbl.find_opt]/[Hashtbl.replace]
   never yield to another fiber, so nothing can observe or mutate this state mid-check. *)
module Blocking_kv_store : sig
  type t

  val create : unit -> t
  val block : t -> key:string -> unit
  val release : t -> key:string -> unit
  val owner : t -> string
  val get : t -> key:string -> string option
  val put : t -> key:string -> string -> unit
  val delete : t -> key:string -> unit
end = struct
  type t = { tbl : (string, string) Hashtbl.t; mutable blocked : string list; cond : Eio.Condition.t }

  let create () = { tbl = Hashtbl.create 16; blocked = []; cond = Eio.Condition.create () }
  let owner _ = "blocking-mock"

  let block t ~key = t.blocked <- key :: t.blocked

  let release t ~key =
    t.blocked <- List.filter (fun k -> k <> key) t.blocked;
    Eio.Condition.broadcast t.cond

  let get t ~key =
    while List.mem key t.blocked do
      Eio.Condition.await_no_mutex t.cond
    done;
    Hashtbl.find_opt t.tbl key

  let put t ~key value = Hashtbl.replace t.tbl key value
  let delete t ~key = Hashtbl.remove t.tbl key
end

module GMB = Riptide_materialize.Materializer.Make (G_set) (Blocking_kv_store)

(* Distinguishes real per-[merge_key] locking from an accidental single-global-lock
   implementation, which a hashtable-of-mutexes fix could regress to just as easily as it could
   fix the lost-update bug (e.g. one shared [Eio.Mutex.t] on [t] instead of one per key). If
   [write] took one lock covering every [merge_key]: the "a" fiber runs first (per
   [Eio.Fiber.both]'s documented scheduling), takes that global lock, then suspends inside
   [Blocking_kv_store.get] waiting on the block -- while STILL HOLDING the lock. The "b" fiber
   would then also block trying to take the same global lock before it could even reach its own
   [KV.get], so [b_done] would never become [true] and [release] would never be called -- a real
   deadlock, not just a slow pass. [Eio.Time.with_timeout] below turns that deadlock into a clean,
   fast test failure instead of hanging the suite forever. *)
let test_writes_to_different_merge_keys_are_not_serialized () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let kv = Blocking_kv_store.create () in
  let m = GMB.create ~kv ~owner:"blocking-mock" ~decode:g_set_decode ~encode:g_set_encode in
  Blocking_kv_store.block kv ~key:"a";
  let b_done = ref false in
  let outcome =
    Eio.Time.with_timeout clock 5.0 (fun () ->
        Eio.Fiber.both
          (fun () -> GMB.write m ~merge_key:"a" (G_set.of_list [ "from-a" ]))
          (fun () ->
            GMB.write m ~merge_key:"b" (G_set.of_list [ "from-b" ]);
            b_done := true;
            Blocking_kv_store.release kv ~key:"a");
        Ok ())
  in
  (match outcome with
  | Ok () -> ()
  | Error `Timeout ->
    Alcotest.fail
      "writing merge_key \"b\" waited on merge_key \"a\"'s write -- this is a single global lock, \
       not per-merge_key serialization");
  Alcotest.(check bool)
    "the \"b\" write completed independently of \"a\"'s still-blocked write" true !b_done;
  Alcotest.(check (list string))
    "\"a\"'s write still converged once unblocked" [ "from-a" ]
    (G_set.elements (GMB.read m ~merge_key:"a"));
  Alcotest.(check (list string))
    "\"b\"'s write is unaffected by \"a\"'s lock" [ "from-b" ]
    (G_set.elements (GMB.read m ~merge_key:"b"))

let tests =
  [ ("convergence regardless of fold order", `Quick, test_convergence_regardless_of_fold_order);
    ( "create rejects a kv tagged for a different owner",
      `Quick,
      test_create_rejects_a_kv_tagged_for_a_different_owner );
    ( "create accepts a kv tagged for a matching caller-supplied owner",
      `Quick,
      test_create_accepts_a_kv_tagged_for_a_matching_caller_supplied_owner );
    ( "concurrent writers to one merge_key lose no updates",
      `Quick,
      test_concurrent_writers_to_one_merge_key_lose_no_updates );
    ( "writes to different merge_keys are not serialized against each other",
      `Quick,
      test_writes_to_different_merge_keys_are_not_serialized ) ]
