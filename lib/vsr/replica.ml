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
     op-number (a cumulative high-water mark, never regressed -- see handle_prepare_ok).
     INVARIANT, maintained solely by handle_prepare_ok's own range check below: every key in this
     table is always a valid replica id in [1, replica_count] (VSR.tla's own [replicas ==
     1..ReplicaCount], VSR.tla:15) -- a decoded [Prepare_ok]'s [i] field that falls outside that
     range is rejected before it ever reaches this table, never merely filtered out later when
     read (see the fix-round report for why an id-range check belongs at the point of insertion,
     not scattered across every reader). *)
  peer_op_number : (int, int) Hashtbl.t;
  send : to_:int -> string -> unit;
}

let create ~my_id ~replica_count ~primary_id ~send =
  if replica_count < 1 then invalid_arg "Replica.create: replica_count must be >= 1";
  if replica_count mod 2 = 0 then
    invalid_arg
      "Replica.create: replica_count must be odd -- VSR.tla:140's own comment assumes 2f+1 = \
       ReplicaCount, and VSR.cfg never instantiates an even count";
  if my_id < 1 || my_id > replica_count then
    invalid_arg "Replica.create: my_id must be in [1, replica_count] (VSR.tla's replicas == 1..ReplicaCount)";
  if primary_id < 1 || primary_id > replica_count then
    invalid_arg "Replica.create: primary_id must be in [1, replica_count] (VSR.tla's replicas == 1..ReplicaCount)";
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

(* ---- IsCommitted / PrimaryExecuteOp (VSR.tla:138-155) ----
   Defined ahead of [propose]/[handle_prepare_ok] because BOTH drive it: see the doc comment on
   [primary_execute_op] below, and replica.mli's own note on why [propose] must also call it
   (VSR.tla's [PrimaryExecuteOp] guard has two conjuncts, and [ReceiveClientRequest] -- i.e.
   [propose] -- is the action that changes the FIRST one, [rep_commit_number[r] <
   rep_op_number[r]], not just [ReceivePrepareOkMsg]). *)

let is_committed_quorum t ~op_number =
  let f = (t.replica_count - 1) / 2 in
  (* [peer <> t.my_id] is VSR.tla's own [\ {r}] exclusion. The [p \in replicas] range check that
     VSR.tla:141's set comprehension also requires is enforced once, at insertion, by
     [handle_prepare_ok]'s own range check (see [peer_op_number]'s own doc comment above) -- every
     key already in this table is guaranteed in [1, replica_count], so no second check is needed
     here. *)
  let acked_backups =
    Hashtbl.fold
      (fun peer acked_n acc -> if peer <> t.my_id && acked_n >= op_number then acc + 1 else acc)
      t.peer_op_number 0
  in
  acked_backups >= f

(* Advances commit_number strictly one step at a time, from commit_number+1 upward, stopping at
   the first not-yet-committed op-number (or once commit_number = op_number t). Deliberately
   never jumps directly to the triggering Prepare_ok's own [n] -- see replica.mli's own doc
   comment on handle_message for exactly why that would be wrong.

   Called from BOTH [propose] and [handle_prepare_ok]: [PrimaryExecuteOp]'s guard
   (VSR.tla:145-150) is a conjunction of [rep_commit_number[r] < rep_op_number[r]] (changed by
   [ReceiveClientRequest], i.e. [propose]) and [IsCommitted(r, next)] (changed by
   [ReceivePrepareOkMsg], i.e. [handle_prepare_ok]) -- either action can newly enable it, so both
   must drive it. For [replica_count >= 3] (so [f >= 1]) calling it from [propose] is a provable
   no-op, since a fresh op with zero acks never satisfies [IsCommitted]; it only has a visible
   effect in the degenerate [f = 0] case ([replica_count = 1]), where [IsCommitted] is vacuously
   true for every op-number and the primary can commit its own proposal with no acks at all,
   matching what VSR.tla's own [Next] would allow (nothing stops [PrimaryExecuteOp] from firing
   immediately after [ReceiveClientRequest] in that case). *)
let primary_execute_op t =
  let continue_ = ref true in
  while !continue_ do
    if t.commit_number >= op_number t then continue_ := false
    else begin
      let next = t.commit_number + 1 in
      if is_committed_quorum t ~op_number:next then t.commit_number <- next else continue_ := false
    end
  done

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
    done;
    primary_execute_op t (* see primary_execute_op's own doc comment for why this call is needed *)
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
      (* VSR.tla:106-109's own comment argues the unguarded [m.k > @] update (VSR.tla:118) is safe
         because a well-formed [Prepare] always has [m.k < m.n] -- a property only true of
         messages produced by the spec's OWN actions, which a decoded, possibly network-corrupted
         message is not guaranteed to have. [k <= op_number t] (== [m.n], just appended above)
         re-establishes that precondition explicitly instead of trusting it, so a corrupted/forged
         [k] can never push commit_number past what this replica's own log actually contains --
         preserving [CommitNumberNeverHigherThanOpNumber] (VSR.tla:330-331) for every input, not
         just well-formed ones. A genuinely higher, in-range [k] from a well-formed message is
         still applied exactly as before. *)
      if k > t.commit_number && k <= op_number t then t.commit_number <- k;
      let reply = Message.encode (Message.Prepare_ok { view = normal_view; n; i = t.my_id }) in
      t.send ~to_:t.primary_id reply

(* ---- ReceivePrepareOkMsg (VSR.tla:125-136) ---- *)

let handle_prepare_ok t ~view ~n ~i =
  if not (is_primary t) then ()
  else if view <> normal_view then ()
  else if i < 1 || i > t.replica_count then
    () (* VSR.tla:141's own [p \in replicas] domain restriction -- a decoded [i] naming no real
          replica must never be allowed into [peer_op_number] at all (see that field's own doc
          comment above for why this is the single point where the invariant is established) *)
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
