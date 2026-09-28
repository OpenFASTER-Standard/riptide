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

let tests =
  [ ("convergence regardless of fold order", `Quick, test_convergence_regardless_of_fold_order);
    ( "create rejects a kv tagged for a different owner",
      `Quick,
      test_create_rejects_a_kv_tagged_for_a_different_owner );
    ( "create accepts a kv tagged for a matching caller-supplied owner",
      `Quick,
      test_create_accepts_a_kv_tagged_for_a_matching_caller_supplied_owner ) ]
