(* lib/storage/superblock_record.ml -- see superblock_record.mli for what this module is for, why it
   lives in [riptide_storage] rather than [riptide_vsr], and the hand-sync hazard it closes. *)

type t = {
  view_number : int;
  last_normal_view : int;
  op_number : int;
  commit_number : int;
}

(* Field order is ALPHABETICAL, and that is not cosmetic: {!Riptide.Value.canonical_encode} is a
   canonical encoder, so the bytes are a function of the record's contents alone -- but keeping the
   source order canonical too means a reader diffing this against a decoded record, or against
   [Riptide_vsr.Replica]'s own former copy of this function, is comparing like with like. *)
let encode { view_number; last_normal_view; op_number; commit_number } =
  let int_field name i = (name, Riptide.Value.Scalar (Riptide.Value.Int (Int64.of_int i))) in
  Riptide.Value.canonical_encode
    (Riptide.Value.Record
       [ int_field "commit_number" commit_number;
         int_field "last_normal_view" last_normal_view;
         int_field "op_number" op_number;
         int_field "view_number" view_number
       ])

let decode (bytes : string) =
  match Riptide.Value.canonical_decode bytes with
  | exception Invalid_argument _ -> None
  | Riptide.Value.Record fields ->
    let int_field name =
      match List.assoc_opt name fields with
      | Some (Riptide.Value.Scalar (Riptide.Value.Int i)) ->
        let i = Int64.to_int i in
        if i < 0 then None else Some i
      | _ -> None
    in
    (match
       ( int_field "view_number",
         int_field "last_normal_view",
         int_field "op_number",
         int_field "commit_number" )
     with
    | Some view_number, Some last_normal_view, Some op_number, Some commit_number
      when commit_number <= op_number ->
      Some { view_number; last_normal_view; op_number; commit_number }
    | _ -> None)
  | _ -> None

(* The two messages below are VALUES rather than inlined string literals, and exported, specifically
   so a test asserting on one references the same thing the implementation raises -- the drift review
   finding M10 names. Before this, the check AND its message existed in two independently typed-out
   copies (one per backend) plus a third hand-typed copy in a test's [check_raises]. *)
let refusal_superblock_already_readable =
  "superblock_rebuild_from_wal: superblock_read is not None -- refusing to rebuild over an \
   already-usable superblock"

let refusal_empty_wal =
  "superblock_rebuild_from_wal: the WAL is empty -- there is no lost superblock to repair here, \
   this is FIRST BOOT (Replica.create/Replica.restart both handle an empty backend correctly on \
   their own). Writing a superblock over a virgin backend would permanently foreclose \
   Replica.create, which refuses if any superblock already exists."

let check_rebuild_precondition ~superblock_read ~durable_op_number =
  if superblock_read <> None then invalid_arg refusal_superblock_already_readable;
  if durable_op_number <= 0 then invalid_arg refusal_empty_wal

let check_rebuild_values ~view_number ~last_normal_view ~op_number ~commit_number =
  if view_number < 0 || last_normal_view < 0 || commit_number < 0 then
    invalid_arg
      (Printf.sprintf
         "superblock_rebuild_from_wal: view_number/last_normal_view/commit_number must all be >= 0 \
          (VSR.tla types every one of them Nat); got view_number = %d, last_normal_view = %d, \
          commit_number = %d"
         view_number last_normal_view commit_number);
  if commit_number > op_number then
    invalid_arg
      (Printf.sprintf
         "superblock_rebuild_from_wal: commit_number %d exceeds the op_number %d this backend's own \
          WAL can account for -- CommitNumberNeverHigherThanOpNumber (VSR.tla:721-722). Supply THIS \
          replica's own commit_number, which is necessarily <= its own op_number, not the cluster's \
          if the two differ."
         commit_number op_number);
  if last_normal_view > view_number then
    invalid_arg
      (Printf.sprintf
         "superblock_rebuild_from_wal: last_normal_view %d exceeds view_number %d -- \
          last_normal_view is the last view in which this replica was Normal, so it can never be \
          ahead of the view it is currently in (and the pair is what Replica.restart reconstructs \
          status from)."
         last_normal_view view_number)
