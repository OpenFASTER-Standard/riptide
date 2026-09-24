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
      (* [~owner:"materializer"] on every real materializer-backing store in this repo, per
         materializer.mli's own instruction to the caller building the [kv]: the guard added in
         subtask 4.6 only protects a directory that its consumers actually claim. *)
      let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" dir in
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
  (* Check that all orderings converge to the same value *)
  Alcotest.(check bool) "forward and reversed order converge to the same value" true
    (forward = reversed);
  Alcotest.(check bool) "shuffled order also converges to the same value" true
    (forward = shuffled);
  (* Check that the converged value equals the expected result: timestamp 3, value "c" *)
  let expected = { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String "c"); timestamp = 3L } in
  Alcotest.(check bool) "converges to the expected LWW value (highest timestamp wins)" true
    (forward = expected)

let tests = [ ("convergence regardless of fold order", `Quick, test_convergence_regardless_of_fold_order) ]
