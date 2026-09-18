(* lib/vsr/replica.ml -- see replica.mli for the full cross-check against spec/tla/VSR.tla,
   including exact line citations for every guard/effect transcribed below. *)

open Riptide

(* This plan's scope is normal-case only, with a fixed primary -- every message this replica
   sends or accepts carries view 0 (VSR.tla's [rep_view_number[r]] starts at 0 at [Init] and this
   module never changes it). Named rather than a bare literal so every guard/construction site
   below reads as "the view", not a magic number. *)
let normal_view = 0

type t = {
  my_id : int;
  replica_count : int;
  primary_id : int;
  log : Replica_log.t;
  mutable commit_number : int;
  (* Primary-only bookkeeping (VSR.tla's [rep_peer_op_number[r]]) -- harmless, simply never
     populated, on a backup. Keyed by peer replica id, value is that peer's highest acknowledged
     op-number (a cumulative high-water mark, never regressed -- see handle_prepare_ok). *)
  peer_op_number : (int, int) Hashtbl.t;
  send : to_:int -> string -> unit;
}

let create ~my_id ~replica_count ~primary_id ~send =
  {
    my_id;
    replica_count;
    primary_id;
    log = Replica_log.create ();
    commit_number = 0;
    peer_op_number = Hashtbl.create (max 1 (replica_count - 1));
    send;
  }

let is_primary t = t.my_id = t.primary_id
let op_number t = Replica_log.length t.log
let commit_number t = t.commit_number
let entries t = Replica_log.to_list t.log

(* [Value.value] identity for dedup/is_committed purposes: canonical-encoding equality, not
   OCaml's structural [=] -- see replica.mli's own doc comment on [propose] for why (lib/value.mli's
   [Float] case is content-addressed by raw bit pattern, not by OCaml's [=]/[compare]). *)
let value_equal (a : Value.value) (b : Value.value) = Value.canonical_encode a = Value.canonical_encode b

let is_committed t v =
  let rec loop n =
    if n > t.commit_number then false
    else
      match Replica_log.get t.log ~op_number:n with
      | Some x when value_equal x v -> true
      | _ -> loop (n + 1)
  in
  loop 1

(* ---- ReceiveClientRequest (VSR.tla:91-102) ---- *)

let propose t (v : Value.value) =
  if not (is_primary t) then ()
  else if List.exists (fun existing -> value_equal existing v) (entries t) then ()
  else begin
    let n = op_number t + 1 in
    Replica_log.append t.log ~op_number:n v;
    let bytes = Message.encode (Message.Prepare { view = normal_view; n; v; k = t.commit_number }) in
    for peer = 1 to t.replica_count do
      if peer <> t.my_id then t.send ~to_:peer bytes
    done
  end

(* ---- ReceivePrepareMsg (VSR.tla:104-123) ---- *)

let handle_prepare t ~view ~n ~(v : Value.value) ~k =
  if is_primary t then () (* IsNormalBackup(r) guard: not enabled for the primary itself *)
  else if view <> normal_view then ()
  else
    match Replica_log.append t.log ~op_number:n v with
    | exception Replica_log.Out_of_order_append _ ->
      () (* out-of-order: action not enabled, per VSR.tla -- silently drop, no reply, no state change *)
    | () ->
      if k > t.commit_number then t.commit_number <- k;
      let reply = Message.encode (Message.Prepare_ok { view = normal_view; n; i = t.my_id }) in
      t.send ~to_:t.primary_id reply

(* ---- IsCommitted / PrimaryExecuteOp (VSR.tla:138-155), driven from ReceivePrepareOkMsg ---- *)

let is_committed_quorum t ~op_number =
  let f = (t.replica_count - 1) / 2 in
  let acked_backups =
    Hashtbl.fold
      (fun peer acked_n acc -> if peer <> t.my_id && acked_n >= op_number then acc + 1 else acc)
      t.peer_op_number 0
  in
  acked_backups >= f

(* Advances commit_number strictly one step at a time, from commit_number+1 upward, stopping at
   the first not-yet-committed op-number (or once commit_number = op_number t). Deliberately
   never jumps directly to the triggering Prepare_ok's own [n] -- see replica.mli's own doc
   comment on handle_message for exactly why that would be wrong. *)
let primary_execute_op t =
  let continue_ = ref true in
  while !continue_ do
    if t.commit_number >= op_number t then continue_ := false
    else begin
      let next = t.commit_number + 1 in
      if is_committed_quorum t ~op_number:next then t.commit_number <- next else continue_ := false
    end
  done

(* ---- ReceivePrepareOkMsg (VSR.tla:125-136) ---- *)

let handle_prepare_ok t ~view ~n ~i =
  if not (is_primary t) then ()
  else if view <> normal_view then ()
  else begin
    let prev = Option.value (Hashtbl.find_opt t.peer_op_number i) ~default:0 in
    if n > prev then Hashtbl.replace t.peer_op_number i n;
    primary_execute_op t
  end

let handle_message t (bytes : string) =
  match Message.decode bytes with
  | exception Message.Malformed_message _ -> ()
  | Message.Prepare { view; n; v; k } -> handle_prepare t ~view ~n ~v ~k
  | Message.Prepare_ok { view; n; i } -> handle_prepare_ok t ~view ~n ~i
  | Message.Start_view_change _ | Message.Do_view_change _ | Message.Start_view _ ->
    () (* out of this plan's scope -- silently ignored, not raised *)
