(* lib/vsr/replica.ml -- see replica.mli for the full cross-check against spec/tla/VSR.tla,
   including exact line citations for every guard/effect transcribed below. *)

open Riptide

(* VSR.tla's own [rep_status] (VSR.tla:29): {"Normal", "ViewChange"}. Renamed [View_change] here
   only for OCaml's own constructor-casing convention -- no semantic change from the spec's own
   string literal. THIS task ([check_timeout]/[handle_message]'s new [Start_view_change] dispatch)
   is the first to actually construct [View_change] for real -- via [TimerSendSVC] and
   [ReceiveHigherSVC] below -- so the earlier plan's placeholder "unused constructor" witness
   binding that used to live here is gone: the compiler now sees [View_change] built for real, at
   multiple call sites, with no need for a dummy binding to justify its existence. *)
type status = Normal | View_change

(* A real replica id set -- VSR.tla's own [rep_recv_svc[r]] (VSR.tla:33) is typed [SUBSET
   replicas], a genuine set with [\cup]/[Cardinality] semantics (ReceiveMatchingSVC's own [@ \cup
   {m.i}], VSR.tla:201; SendDVC's own [Cardinality(rep_recv_svc[r]) >= f], VSR.tla:221) -- so the
   earlier plan's placeholder [int list] representation (justified there only by "never read by
   anything in this plan's scope") is replaced here, now that this task's own [try_send_dvc]
   genuinely needs both dedup (the same sender's StartViewChange arriving twice must not inflate
   the count) and [Cardinality]. *)
module Int_set = Set.Make (Int)

type t = {
  my_id : int;
  replica_count : int;
  svc_limit : int; (* StartViewOnTimerLimit -- bounds check_timeout; read by check_timeout
                       itself, below in this same file. *)
  log : Replica_log.t;
  mutable status : status; (* VSR.tla's [rep_status[r]] (VSR.tla:29). *)
  mutable view_number : int; (* VSR.tla's [rep_view_number[r]] (VSR.tla:30), i.e. [View(r)]. *)
  mutable last_normal_view : int;
  (* VSR.tla's [rep_last_normal_view[r]] (VSR.tla:31) -- the paper's [v'], deliberately NOT
     derivable from [view_number]. Read by try_send_dvc (below, DoViewChange's own
     last_normal_view field); still only ever WRITTEN by test-support code in this task's own
     scope -- SendSV/ReceiveSV (a later task) are the real writers. *)
  mutable commit_number : int;
  mutable recv_svc : Int_set.t;
  (* VSR.tla's [rep_recv_svc[r]] (VSR.tla:33) -- STARTVIEWCHANGE senders for the current
     view-change episode. Written by [check_timeout] (reset to empty, TimerSendSVC, VSR.tla:168),
     [handle_start_view_change]'s two branches (seeded to a singleton, ReceiveHigherSVC,
     VSR.tla:189; unioned, ReceiveMatchingSVC, VSR.tla:201), and read by [try_send_dvc]
     (Cardinality, SendDVC, VSR.tla:221). *)
  mutable recv_dvc : Message.t list;
  (* VSR.tla's [rep_recv_dvc[r]] (VSR.tla:34) -- the raw DOVIEWCHANGE messages received this
     episode. Reset to empty by [check_timeout]/[handle_start_view_change]'s ReceiveHigherSVC
     branch (both begin a new view-change episode, VSR.tla:169, 190) whenever this task's scope
     touches it; still not POPULATED by anything in this task's scope -- [ReceiveDVC], the action
     that adds to it, is Task 3's own territory. *)
  mutable sent_dvc : bool;
  (* VSR.tla's [rep_sent_dvc[r]] (VSR.tla:35) -- the one-shot "already sent my DOVIEWCHANGE for
     this episode" flag [SendDVC] (VSR.tla:216-228) is gated on. Reset to [false] by
     [check_timeout]/[handle_start_view_change]'s ReceiveHigherSVC branch (both begin a new
     episode) and set [true] by [try_send_dvc] once it actually fires. *)
  mutable svc_count : int;
  (* VSR.tla's [aux_svc_count[r]] (VSR.tla:41) -- bounds [check_timeout] (TimerSendSVC,
     VSR.tla:161-174), incremented every time it fires. VSR.tla's own [aux_svc_count] is a pure
     state-space-bounding device for TLC (research §6.3 point 4) and is NEVER reset anywhere in the
     abstract spec -- transcribed literally, a real replica would permanently stop trying to
     trigger a view change after [svc_limit] timeouts, forever, which is clearly wrong for a real
     long-running deployment that needs to recover from repeated primary failures.

     DELIBERATE, DISCLOSED DIVERGENCE from the literal TLA+ transcription (this task's own review
     ruling, not an oversight): [svc_count] must reset to [0] whenever this replica successfully
     returns to [Normal] status by actually COMPLETING a view change -- either by calling [SendSV]
     itself (becoming the new primary) or via [ReceiveSV] (accepting a new primary's [StartView])
     -- since at that point the replica has proven it can reach a working view, and any FUTURE
     timeout represents a genuinely new failure deserving its own fresh budget. Neither [SendSV]
     nor [ReceiveSV] exists yet (both are Task 3's own scope), so nothing in THIS task's scope ever
     resets [svc_count] -- this comment, and the identical one on [check_timeout] below, are the
     hook Task 3 needs: at the exact point each of those two actions sets [status' = "Normal"]
     (VSR.tla:275, 301), it must also add [t.svc_count <- 0] (a direct mutation of this private
     field from within THIS module -- no separate exposed reset function is needed, the same way
     no separate setter exists for any other field only ever written from inside [replica.ml]). *)
  (* Primary-only bookkeeping (VSR.tla's [rep_peer_op_number[r]]) -- harmless, simply never
     populated, on a backup. Keyed by peer replica id, value is that peer's highest acknowledged
     op-number (a cumulative high-water mark, never regressed -- see handle_prepare_ok).
     INVARIANT, maintained solely by handle_prepare_ok's own range check below: every key in this
     table is always a valid replica id in [1, replica_count] (VSR.tla's own [replicas ==
     1..ReplicaCount], VSR.tla:15) -- a decoded [Prepare_ok]'s [i] field that falls outside that
     range is rejected before it ever reaches this table, never merely filtered out later when
     read. Enforcing at the single point of INSERTION rather than at each read is deliberate: it
     gives the invariant exactly one enforcement site that a new reader cannot forget to repeat,
     so [is_committed_quorum] below (and any future reader -- view-change will add more) may take
     "every key here is a real replica id" as given instead of re-deriving it. A range check
     scattered across readers is one missed reader away from the same quorum-inflation bug it was
     added to prevent. *)
  peer_op_number : (int, int) Hashtbl.t;
  send : to_:int -> string -> unit;
}

let create ~my_id ~replica_count ~svc_limit ~send =
  if replica_count < 1 then invalid_arg "Replica.create: replica_count must be >= 1";
  if replica_count mod 2 = 0 then
    invalid_arg
      "Replica.create: replica_count must be odd -- VSR.tla:140's own comment assumes 2f+1 = \
       ReplicaCount, and VSR.cfg never instantiates an even count";
  if my_id < 1 || my_id > replica_count then
    invalid_arg "Replica.create: my_id must be in [1, replica_count] (VSR.tla's replicas == 1..ReplicaCount)";
  if svc_limit < 1 then
    invalid_arg
      "Replica.create: svc_limit must be >= 1 -- VSR.tla:163's own [aux_svc_count[r] < \
       StartViewOnTimerLimit] guard on TimerSendSVC is never satisfiable at aux_svc_count[r] = 0 \
       (Init's own starting value) for a non-positive limit, which would permanently and silently \
       disable view-change from ever starting on this replica";
  {
    my_id;
    replica_count;
    svc_limit;
    log = Replica_log.create ();
    status = Normal;
    view_number = 0;
    (* VSR.tla's [Init] (VSR.tla:79): [rep_view_number = [r \in replicas |-> 0]]. *)
    last_normal_view = 0;
    commit_number = 0;
    recv_svc = Int_set.empty;
    recv_dvc = [];
    sent_dvc = false;
    svc_count = 0;
    peer_op_number = Hashtbl.create (max 1 (replica_count - 1));
    send;
  }

(* [Primary(v) == 1 + ((v-1) % ReplicaCount)] (VSR.tla:18). TLA+'s [%] is Euclidean (floored)
   modulo, always non-negative; OCaml's [mod] follows the sign of the DIVIDEND, so [(v-1) mod
   replica_count] can itself be negative when [v = 0] (or any [v <= 0]). Normalized to the
   Euclidean result via [(x mod n + n) mod n] -- computationally verified against TLC's own
   already-established values (both in the TLA+ spec plan and again for this plan) before being
   written here: at [replica_count = 3], this formula gives [Primary(0) = 3], [Primary(1) = 1],
   [Primary(2) = 2]. See replica.mli's own note on why [Primary(0) = 3], NOT [1], is the trap this
   normalization exists to avoid. *)
let primary t = 1 + (((t.view_number - 1) mod t.replica_count + t.replica_count) mod t.replica_count)

let is_primary t = t.my_id = primary t
let op_number t = Replica_log.length t.log
let commit_number t = t.commit_number
let view_number t = t.view_number
let last_normal_view t = t.last_normal_view
let status t = t.status
let entries t = Replica_log.to_list t.log

(* ---- Test-support surface: NOT part of the protocol. ----
   [t] is abstract, and the real protocol never lets anything other than the view-change actions
   themselves (TimerSendSVC / ReceiveHigherSVC / ReceiveMatchingSVC, implemented below in this
   same file; SendSV / ReceiveSV, a later task) move [view_number]. Tests, though, need a way to
   put a chosen replica id at [primary t]
   without either hand-deriving [Primary(v)] at every call site or waiting for view-change to
   exist. See replica.mli's own doc comment on this function for the exact convention it
   establishes (view_number = 1 always makes replica id 1 the primary, regardless of
   replica_count, since Primary(1) = 1 + ((1-1) mod replica_count) = 1 for any replica_count).

   Also sets [last_normal_view] to the same value [v] -- NOT left untouched. Fix-round finding M3
   (task-1-review.md): a fresh TLC run of a copy of VSR.tla with the added invariant
   [status[r] = "Normal" => last_normal_view[r] = view_number[r]] found ZERO violations across
   264,376 distinct reachable states, so [status = Normal /\ last_normal_view <> view_number] is
   genuinely unreachable in the real protocol -- every spec action that (re-)enters "Normal"
   ([SendSV], VSR.tla:275-276; [ReceiveSV], VSR.tla:301-302) sets [rep_last_normal_view] to the
   new view in the SAME step, and every action that raises [view_number] moves [status] to
   "ViewChange" first (VSR.tla:166-167, 187-188), so the two are never allowed to be Normal and
   mismatched simultaneously. Leaving [last_normal_view] stale here would let every test built on
   this setter silently validate against a protocol-impossible state -- harmless while nothing
   reads [last_normal_view] (this task's own scope), but Task 2/3's [WinningDVC] (VSR.tla:248-255)
   selects the surviving log by [last_normal_view] FIRST, so a falsely-stale value there would
   corrupt exactly the highest-risk logic in the whole plan. Keeping the two fields in sync by
   default is the only reachable choice; a test that genuinely needs them to differ (e.g. to
   construct a mid-view-change state) should use {!for_test_set_view} below, its own, separate
   test-support constructor, rather than repurposing this one. *)
let for_test_set_view_number t v =
  t.view_number <- v;
  t.last_normal_view <- v

(* Prescribed by replica.mli's own note on [for_test_set_view_number] (task-1-review.md's M3
   fix-round finding): [for_test_set_view_number] is correct ONLY for [status = Normal] (it forces
   [last_normal_view = view_number] in lockstep, matching the spec's confirmed
   [status = "Normal" => last_normal_view = view_number] invariant) -- reusing it to build a
   [View_change]-status test state would silently construct the exact mirror-image bug that
   fix-round finding fixed for the Normal case: a [View_change]-status replica's [last_normal_view]
   is very often DIFFERENT from its [view_number] (that is the whole point of the field -- see
   VSR.tla:31's own comment, "the paper's v', NOT derivable from rep_view_number"), so a setter that
   force-synced the two would make it impossible to construct the realistic test states
   [WinningDVC] (VSR.tla:248-255) itself depends on selecting between. This setter therefore sets
   all three fields directly and independently, with no synchronization -- the caller is
   responsible for choosing a combination that is actually reachable if that matters for what it's
   testing. *)
let for_test_set_view t ~status:s ~view_number ~last_normal_view =
  t.status <- s;
  t.view_number <- view_number;
  t.last_normal_view <- last_normal_view

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
  if t.status <> Normal then () (* IsNormalPrimary(r) guard: not enabled outside status="Normal" *)
  else if not (is_primary t) then () (* IsNormalPrimary(r) guard's other conjunct: r = Primary(View(r)) *)
  else if List.exists (fun existing -> value_equal existing v) (entries t) then ()
  else begin
    let n = op_number t + 1 in
    Replica_log.append t.log ~op_number:n v;
    let bytes = Message.encode (Message.Prepare { view = t.view_number; n; v; k = t.commit_number }) in
    for peer = 1 to t.replica_count do
      if peer <> t.my_id then t.send ~to_:peer bytes
    done;
    primary_execute_op t (* see primary_execute_op's own doc comment for why this call is needed *)
  end

(* ---- ReceivePrepareMsg (VSR.tla:104-123) ---- *)

let handle_prepare t ~view ~n ~(v : Value.value) ~k =
  if t.status <> Normal then () (* IsNormalBackup(r) guard: not enabled outside status="Normal" *)
  else if is_primary t then () (* IsNormalBackup(r) guard's other conjunct: not enabled for the primary itself *)
  else if view <> t.view_number then ()
  else
    match Replica_log.append t.log ~op_number:n v with
    | exception Replica_log.Out_of_order_append _ ->
      () (* out-of-order: action not enabled, per VSR.tla -- silently drop, no reply, no state change *)
    | () ->
      (* VSR.tla:106-109's own comment argues the unguarded [m.k > @] update (VSR.tla:118) is safe
         because a well-formed [Prepare] always has [m.k < m.n] -- a property only true of
         messages produced by the spec's OWN actions, which a decoded, possibly network-corrupted
         message is not guaranteed to have. [k <= op_number t] (== [m.n], just appended above)
         bounds [k] explicitly instead of trusting that precondition, so a corrupted/forged [k]
         can never push commit_number past what this replica's own log actually contains --
         preserving [CommitNumberNeverHigherThanOpNumber] (VSR.tla:330-331) for every input, not
         just well-formed ones. A genuinely higher, in-range [k] from a well-formed message is
         still applied exactly as before.

         This bound is deliberately ONE STEP WIDER than the spec's own precondition, and does NOT
         re-establish it exactly: it admits [k = n], which VSR.tla:106-109's [m.k < m.n] excludes
         and no correct primary ever sends ([m.k] is its commit-number from strictly BEFORE this
         request was appended). The extra step is a defense-in-depth margin against off-by-one
         edge cases, and is harmless in this plan's scope -- at [k = n] the entry at [n] exists
         and [commit_number = op_number], so [CommitNumberNeverHigherThanOpNumber] and
         [NoLogDivergence] both still hold. test_vsr_replica.ml's own k-boundary tests pin all
         three of [k = n-1] (well-formed, accepted), [k = n] (the widened margin, accepted) and
         [k = n+1] (rejected), so the exact bound is pinned by tests, not just by this comment.
         FORWARD NOTE: tightening to [k < op_number t] is the safer direction once view-change
         lands -- a backup's commit_number stops being purely local there, since it is sent as
         [DoViewChange.k] and feeds [HighestCommitNumber] (VSR.tla:257-260), so a
         falsely-inflated-by-one backup commit_number becomes load-bearing rather than benign. *)
      if k > t.commit_number && k <= op_number t then t.commit_number <- k;
      let reply = Message.encode (Message.Prepare_ok { view = t.view_number; n; i = t.my_id }) in
      t.send ~to_:(primary t) reply

(* ---- ReceivePrepareOkMsg (VSR.tla:125-136) ---- *)

let handle_prepare_ok t ~view ~n ~i =
  if t.status <> Normal then () (* IsNormalPrimary(r) guard: not enabled outside status="Normal" *)
  else if not (is_primary t) then ()
  else if view <> t.view_number then ()
  else if i < 1 || i > t.replica_count then
    () (* VSR.tla:141's own [p \in replicas] domain restriction -- a decoded [i] naming no real
          replica must never be allowed into [peer_op_number] at all (see that field's own doc
          comment above for why this is the single point where the invariant is established) *)
  else if n > op_number t then
    () (* A genuine [Prepare_ok] can never legitimately claim to have acked an op-number higher
          than what THIS primary has itself assigned via a Prepare broadcast -- op-numbers are
          minted only by this replica's own log (op_number t = Replica_log.length), so [m.n]
          can be at most that. Left unbounded, a forged (or corrupted) [n] from an otherwise
          real replica id permanently pre-acks every future op this primary ever proposes,
          letting it "commit" with zero real acks once op_number catches up -- the same
          AcknowledgedWritesExistOnMajority violation M1/M2 were fixed against, just via [n]
          instead of [i]/[k]. *)
  else begin
    let prev = Option.value (Hashtbl.find_opt t.peer_op_number i) ~default:0 in
    if n > prev then Hashtbl.replace t.peer_op_number i n;
    primary_execute_op t
  end

(* ---- SendDVC (VSR.tla:216-228) ----
   Driven from every point [recv_svc] actually changes -- [check_timeout]'s own reset to empty,
   and [handle_start_view_change]'s two branches (seed / union) below -- mirroring the normal-case
   plan's [PrimaryExecuteOp]-driven-from-both-[propose]-and-[handle_prepare_ok] pattern exactly: a
   guard with several conjuncts (here [status = View_change], [not sent_dvc], and
   [Cardinality(recv_svc) >= f]) needs a check after EVERY action that can change any one of them,
   not just some of them -- polling from a single call site would miss the others. [check_timeout]'s
   own call is a genuine no-op in every cluster with [f >= 1] (a fresh, empty [recv_svc] can never
   satisfy [Cardinality(recv_svc) >= f] for a positive [f]) -- it only has a real effect in the
   degenerate [f = 0] (replica_count = 1) cluster, where [Cardinality({}) = 0 >= f = 0] is already
   true the instant [check_timeout] itself flips [status] to [View_change]. Included anyway, for
   the same reason [propose]'s own call to [primary_execute_op] is: leaving out the point that only
   matters in the degenerate case is exactly the kind of asymmetry a future refactor could silently
   depend on being "always a no-op" and get wrong. *)
let try_send_dvc t =
  let f = (t.replica_count - 1) / 2 in
  if t.status = View_change && (not t.sent_dvc) && Int_set.cardinal t.recv_svc >= f then begin
    let bytes =
      Message.encode
        (Message.Do_view_change
           {
             v = t.view_number;
             log = entries t;
             last_normal_view = t.last_normal_view;
             n = op_number t;
             k = t.commit_number;
             i = t.my_id;
           })
    in
    t.send ~to_:(primary t) bytes;
    t.sent_dvc <- true
  end

(* ---- TimerSendSVC (VSR.tla:161-174) ----
   research §2.1: VSR.tla deliberately does not model real timeouts -- this is an unconditional,
   always-enabled (once its guard holds) action, not something driven by a clock; a caller decides
   when to invoke [check_timeout] (e.g. on an actual timer firing with no Prepare/heartbeat seen
   recently), matching the spec's own framing of it as "bounded by a state-space-limiting counter"
   rather than real wall-clock logic. *)
let check_timeout t =
  if t.svc_count >= t.svc_limit then
    () (* [aux_svc_count[r] < StartViewOnTimerLimit] guard (VSR.tla:163) -- see [svc_count]'s own
          doc comment on [t] for why this bound is NOT permanent in this implementation despite
          [aux_svc_count] never resetting in the literal TLA+ transcription: Task 3's [SendSV]/
          [ReceiveSV] reset it back to 0 on every successful return to [Normal], giving each new
          failure its own fresh budget. *)
  else if t.status <> Normal then () (* [rep_status[r] = "Normal"] guard (VSR.tla:164) *)
  else begin
    let v = t.view_number + 1 in
    t.view_number <- v;
    t.status <- View_change;
    t.recv_svc <- Int_set.empty;
    t.recv_dvc <- [];
    t.sent_dvc <- false;
    t.svc_count <- t.svc_count + 1;
    let bytes = Message.encode (Message.Start_view_change { v; i = t.my_id }) in
    for peer = 1 to t.replica_count do
      if peer <> t.my_id then t.send ~to_:peer bytes
    done;
    try_send_dvc t (* see try_send_dvc's own doc comment for why this call is included *)
  end

(* ---- ReceiveHigherSVC (VSR.tla:183-194) / ReceiveMatchingSVC (VSR.tla:196-205) ----
   [handle_message]'s own [Start_view_change] dispatch below decides which of these two (if
   either) is enabled for a given decoded message. *)
let handle_start_view_change t ~(v : int) ~(i : int) =
  if i < 1 || i > t.replica_count || i = t.my_id then
    () (* Defense-in-depth, not itself a VSR.tla guard -- mirrors [handle_prepare_ok]'s own [m.i]
          check (see [peer_op_number]'s doc comment above for the general rationale): VSR.tla:15's
          own [replicas == 1..ReplicaCount] domain restriction means [rep_recv_svc[r]] can never
          legitimately contain an out-of-range id in the abstract model (every [StartViewChange]
          there is broadcast with [i] set to the sending replica's own, always-valid id), but a
          decoded message off {!Riptide_transport.Transport_intf.S}'s own "no payload integrity"
          wire has no such guarantee. Left unchecked, a single forged [StartViewChange] naming a
          non-existent replica id would inflate [Cardinality(recv_svc)] -- the exact same quorum-
          inflation bug class M1 (task-1-review.md) fixed for [Prepare_ok]'s own [i] field, just
          feeding [SendDVC]'s threshold instead of [is_committed_quorum]'s. [i = t.my_id] is
          excluded too: VSR.tla's own [BroadcastFunc] (VSR.tla:56, [replicas \ {source}]) makes
          [m.i = r] structurally unreachable for a [StartViewChange] a correct replica ever
          produces, but this codebase's simulated transport has no self-delivery special case
          ([lib/sim/network.ml]'s [send]/[pump_one] place a self-addressed message straight into
          the sender's own inbox) -- so without this exclusion, a self-addressed [StartViewChange]
          (not even a forgery, just an ordinary broadcast looping back) would count toward this
          replica's own quorum for free (task-2-review.md's M1, reproduced live: one genuine other
          plus one self-addressed message reached [SendDVC]'s threshold with only one real
          corroborator). Dropped WHOLESALE (no state change at all -- view_number/status untouched
          even if [v > view_number] would otherwise adopt it), exactly like a wrong-[i]
          [Prepare_ok]: simpler to reason about than applying every effect except the [recv_svc]
          write, and consistent with this module's established "guard failure => total no-op"
          convention. *)
  else if v > t.view_number then begin
    (* ReceiveHigherSVC (VSR.tla:183-194): a higher view than our own -- assume-mode, adopt it
       unconditionally (no majority needed to START a view change this way; see VSR.tla's own
       comment at ReceiveHigherSVC for the "assume-mode, not increment-mode" citation). *)
    t.view_number <- v;
    t.status <- View_change;
    t.recv_svc <- Int_set.singleton i;
    t.recv_dvc <- [];
    t.sent_dvc <- false;
    try_send_dvc t
  end
  else if v = t.view_number && t.status = View_change then begin
    (* ReceiveMatchingSVC (VSR.tla:196-205): another StartViewChange for the SAME episode we are
       already running -- accumulate. *)
    t.recv_svc <- Int_set.add i t.recv_svc;
    try_send_dvc t
  end
  else
    () (* Matches neither action's guard -- e.g. [v < view_number] (stale), or [v = view_number]
          while [status = Normal] (no view-change episode is running here to join) -- not enabled
          by anything, dropped, the same "no buffering/retry" discipline already established for
          an out-of-order Prepare. *)

let handle_message t (bytes : string) =
  match Message.decode bytes with
  | exception Message.Malformed_message _ -> ()
  | Message.Prepare { view; n; v; k } -> handle_prepare t ~view ~n ~v ~k
  | Message.Prepare_ok { view; n; i } -> handle_prepare_ok t ~view ~n ~i
  | Message.Start_view_change { v; i } -> handle_start_view_change t ~v ~i
  | Message.Do_view_change _ | Message.Start_view _ ->
    () (* out of THIS task's scope -- Task 3's own [SendSV]/[ReceiveSV] -- silently ignored, not
          raised *)
