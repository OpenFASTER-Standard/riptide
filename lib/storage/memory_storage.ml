(* lib/storage/memory_storage.ml -- see memory_storage.mli for what this is for and, more
   importantly, for what it deliberately is NOT (it is not durable across a process exit). *)

type t = {
  wal : (int, string) Hashtbl.t;
  corrupt : (int, unit) Hashtbl.t;
      (* Op-numbers whose entry is present-but-unreadable. Kept as a SEPARATE table rather than
         by deleting the [wal] row, because the difference between the two is the entire point of
         this module's fault-injection support: a deleted row plus a lowered
         [wal_highest_op_number] would be VSR.tla's "absent" (provably never written, and
         therefore nackable), while a corrupt slot must stay inside the WAL's op-number range so
         a reader can tell it holds SOMETHING it simply cannot verify -- VSR.tla:100-150's own
         storage model, whose load-bearing rule is that a durably-written slot can only ever fault
         to "corrupt", never to "absent". *)
  mutable highest : int;
  mutable superblock : string option;
}

let create () = { wal = Hashtbl.create 16; corrupt = Hashtbl.create 4; highest = 0; superblock = None }

let wal_append t ~op_number data =
  if op_number <> t.highest + 1 then
    invalid_arg
      (Printf.sprintf "wal_append: op_number %d is not wal_highest_op_number t + 1" op_number)
  else begin
    Hashtbl.replace t.wal op_number data;
    Hashtbl.remove t.corrupt op_number;
    t.highest <- op_number
  end

let wal_read t ~op_number =
  if op_number < 1 || op_number > t.highest then None
  else if Hashtbl.mem t.corrupt op_number then None
  else Hashtbl.find_opt t.wal op_number

let wal_truncate_after t ~op_number =
  if op_number < t.highest then begin
    for o = op_number + 1 to t.highest do
      Hashtbl.remove t.wal o;
      Hashtbl.remove t.corrupt o
    done;
    t.highest <- max 0 op_number
  end

let wal_highest_op_number t = t.highest
let superblock_write t data = t.superblock <- Some data
let superblock_read t = t.superblock

let for_test_corrupt t ~op_number =
  if op_number >= 1 && op_number <= t.highest then Hashtbl.replace t.corrupt op_number ()

(* Deliberately asymmetric with [for_test_corrupt] above, and the asymmetry is the point.
   A WAL slot must never fault from "written" to "provably absent" -- that is VSR.tla's own
   load-bearing modelling decision (VSR.tla:111-150). The SUPERBLOCK has no such rule: it is a
   single record written by three independent, non-atomic copy writes, and
   [File_storage.superblock_read] genuinely and routinely returns [None] whenever fewer than 2 of
   those 3 copies verify and agree -- which a crash between any copy's header write and its data
   write produces on its own, with no injected fault at all. So "the superblock is simply gone"
   is a real, reachable state this module must be able to express, and it is exactly the state
   [Riptide_vsr.Replica.restart]'s fail-stop guard exists for. The WAL is left completely
   untouched: the dangerous shape is precisely a LOST SUPERBLOCK over an INTACT WAL. *)
let for_test_lose_superblock t = t.superblock <- None
