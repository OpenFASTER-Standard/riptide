(* lib/vsr/replica_log.ml *)

open Riptide

type t = {
  mutable entries : Value.value list (* reverse order: newest first, matching lib/log.ml's own convention *);
  mutable count : int;
}

exception Out_of_order_append of { expected : int; got : int }

let create () = { entries = []; count = 0 }

let length t = t.count

let append t ~op_number (v : Value.value) =
  let expected = t.count + 1 in
  if op_number <> expected then raise (Out_of_order_append { expected; got = op_number })
  else begin
    t.entries <- v :: t.entries;
    t.count <- expected
  end

let get t ~op_number =
  if op_number < 1 || op_number > t.count then None
  else
    (* [t.entries] is newest-first, so op-number [op_number] (1-indexed, oldest-first per
       VSR.tla's own Seq indexing) sits at reverse-index [t.count - op_number] from the head. *)
    List.nth_opt t.entries (t.count - op_number)

let replace_with t (log : Value.value list) =
  t.entries <- List.rev log;
  t.count <- List.length log

let to_list t = List.rev t.entries
