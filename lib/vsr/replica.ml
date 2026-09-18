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

(* One received DOVIEWCHANGE, as an element of VSR.tla's own [rep_recv_dvc[r]] (VSR.tla:34, typed
   [SUBSET [message]] -- a set of message RECORDS). Exactly the six fields [SendDVC]'s own record
   literal carries (VSR.tla:222-224), minus [type]/[dest] (constant/implied here -- see
   message.mli's own note on why [dest] is not on the wire at all in this implementation).

   Why a dedicated record rather than storing the decoded [Message.t] variant itself (the shape
   task-3-brief.md sketches as "e.g. [(int, Message.t) Hashtbl.t]"): the two are equivalent in
   content, but every reader below ([winning_dvc], [highest_commit_number], [valid_dvc]) wants the
   six fields directly, and a [Message.t] would force each of them to re-match the variant and
   handle four constructor cases that [receive_dvc] structurally never inserts -- an unreachable
   catch-all arm in the single highest-risk function in this module. Keying and first-wins
   semantics (the actual substance of that brief decision) are unchanged; see
   [handle_do_view_change] below. *)
type dvc = {
  dvc_v : int;
  dvc_log : Value.value list;
  dvc_last_normal_view : int;
  dvc_n : int;
  dvc_k : int;
  dvc_i : int;
}

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
  recv_dvc : (int, dvc) Hashtbl.t;
  (* VSR.tla's [rep_recv_dvc[r]] (VSR.tla:34) -- the DOVIEWCHANGE messages received this episode.
     Reset to empty by [check_timeout]/[handle_start_view_change]'s ReceiveHigherSVC branch (both
     begin a new view-change episode, VSR.tla:169, 190) and populated by [handle_do_view_change]
     ([ReceiveDVC], VSR.tla:232-240). Read only by [try_send_sv] ([SendSV], VSR.tla:264-280).

     DELIBERATE, DISCLOSED DIVERGENCE from a literal transcription of VSR.tla:34's own
     [SUBSET [message]] type, resolved by task-3-brief.md and reproduced here so the reasoning
     lives next to the code: this is a table KEYED BY SENDER ([m.i]), not a set of message records.
     In the abstract model a set-of-records is safe, because a correct replica sends exactly one
     DOVIEWCHANGE per view-change episode ([rep_sent_dvc]'s own one-shot semantics on the sending
     side) and TLA+'s message bag cannot corrupt anything -- so "one element per sender" and "one
     element per distinct record" coincide. Neither premise survives contact with this codebase's
     real simulated transport: [lib/sim/network.ml] injects both [duplicate_probability] AND
     [corrupt_probability], so the same sender's DOVIEWCHANGE can arrive twice with DIFFERENT bytes
     (one pristine copy, one independently corrupted copy). Under a literal set-of-records those
     are two distinct elements, and [SendSV]'s own [Cardinality(...) >= f + 1] threshold
     (VSR.tla:269) would count ONE sender twice -- while VSR.tla:262-263's own citation requires
     "f+1 DOVIEWCHANGE from DIFFERENT replicas, including itself". Counting messages instead of
     senders is a literal reading of the TLA+ text and the WRONG semantics for a real adversarial
     network: it is the historical 114-step-counterexample bug class (quorum inflation during view
     change) reached by a different route.

     FIRST-WINS, NOT LAST-WINS: once a sender has an entry for the CURRENT episode, every later
     arrival from that same sender is ignored -- a genuine retransmission, a duplicate-injected
     copy, and a corrupted duplicate are indistinguishable at this layer, so the rule that keeps
     the most trustworthy state is "keep the first, never let a later arrival overwrite an earlier
     one". Last-wins would let a single corrupted duplicate replace an already-accepted, valid DVC
     (its [log]/[n]/[k] are what [WinningDVC]/[HighestCommitNumber] then select over). See
     [handle_do_view_change] below for the one nuance: an entry left over from an OLDER view (only
     reachable via [ReceiveSV], the sole action that raises [view_number] without clearing this
     table) is NOT protected by first-wins, since it does not belong to the current episode at
     all. *)
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

     DELIBERATE, DISCLOSED DIVERGENCE from the literal TLA+ transcription (an earlier task's own
     review ruling, not an oversight): [svc_count] must reset to [0] whenever this replica
     successfully returns to [Normal] status by actually COMPLETING a view change -- either by
     calling [SendSV] itself (becoming the new primary) or via [ReceiveSV] (accepting a new
     primary's [StartView]) -- since at that point the replica has proven it can reach a working
     view, and any FUTURE timeout represents a genuinely new failure deserving its own fresh
     budget. BOTH resets are now implemented, in [try_send_sv] and [handle_start_view] below, at
     the exact point each action sets [status' = "Normal"] (VSR.tla:275, 301).

     The two are NOT symmetric, and the asymmetry is deliberate (task-3-brief.md's own resolved
     design decision 3): [SendSV]'s guard already requires [rep_status[r] = "ViewChange"]
     (VSR.tla:267), so its reset is unconditional and can only ever fire on a real
     View_change -> Normal transition. [ReceiveSV]'s guard is [m.v >= View(r)] (VSR.tla:295 --
     [>=], not [>]) with NO status conjunct at all, so it genuinely fires on a duplicate or
     replayed [StartView] for the view this replica is ALREADY Normal in. Resetting [svc_count]
     unconditionally there would let a stream of duplicate [StartView]s (not hypothetical --
     [lib/sim/network.ml] has a real [duplicate_probability]) refresh this replica's timeout budget
     indefinitely, silently nullifying the [svc_limit] bound the whole mechanism exists to enforce.
     [handle_start_view] therefore resets only on an actual [View_change -> Normal] transition. *)
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
    recv_dvc = Hashtbl.create (max 1 replica_count);
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

         SETTLED (this was the FORWARD NOTE an earlier task left here, and this task is the moment
         it predicted): the bound is now [k < op_number t], exactly VSR.tla:106-109's own
         [m.k < m.n] precondition, no longer one step wider. It used to admit [k = n] as a
         deliberate defense-in-depth margin, justified solely by [k = n] being harmless while a
         backup's commit_number was purely local state -- at [k = n] the entry at [n] exists and
         [commit_number = op_number], so [CommitNumberNeverHigherThanOpNumber] and
         [NoLogDivergence] both still held. That justification is now GONE: this task wires
         [try_send_dvc] (already merged) into [ReceiveDVC]/[HighestCommitNumber]/[SendSV] below, so
         a backup's commit_number leaves the replica as [DoViewChange.k] and feeds
         [HighestCommitNumber] (VSR.tla:257-260) -- an INDEPENDENT maximum over all valid DVCs' [k]
         fields, NOT derived from the winning DVC. A backup whose commit_number was inflated by one
         by a corrupted [Prepare] therefore becomes the new primary's own commit_number and is
         broadcast cluster-wide as [StartView.k], where it can exceed the winning log's own length.
         The margin is no longer benign, so it is gone: [k = n] is now REJECTED (only the [k]
         field's effect is dropped -- the Prepare itself is still appended and still acked, exactly
         as for the out-of-bound case this bound has always rejected). test_vsr_replica.ml's own
         k-boundary tests pin all three of [k = n-1] (well-formed, accepted), [k = n] (now
         rejected) and [k = n+1] (rejected). *)
      if k > t.commit_number && k < op_number t then t.commit_number <- k;
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
    Hashtbl.reset t.recv_dvc;
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
    Hashtbl.reset t.recv_dvc;
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

(* ---- ValidDvc (VSR.tla:230) ----
   [ValidDvc(r, m) == m.v = View(r)] -- verbatim. This is the view-filtered DVC quorum-counting fix
   for the original formalization's own published 114-step safety counterexample (spec/tla/README.md,
   "What the ValidDvc filter is actually doing here"). It is applied in BOTH places VSR.tla applies
   it: as [ReceiveDVC]'s own guard (VSR.tla:235, in [handle_do_view_change] below) and AGAIN as a
   filter at every read (VSR.tla:258, 269 -- [valid_dvcs] below). The second application is
   currently inert in the abstract model, exhaustively (TLC: [RecvDvcValidWhenViewChange] holds on
   all 264,376 reachable states, because both actions that enter [View_change] reset [recv_dvc]
   first) -- spec/tla/README.md's own conclusion is that it stays anyway, since its redundancy is a
   property of the current reset discipline rather than of the protocol. Same conclusion here: the
   filter is kept, not optimized away. *)
let valid_dvc t (d : dvc) = d.dvc_v = t.view_number

(* The set VSR.tla writes as [{ m \in rep_recv_dvc[r] : ValidDvc(r, m) }] (VSR.tla:258, 269),
   materialized once per read. Sorted by sender id purely for DETERMINISM: [Hashtbl.fold]'s order
   is unspecified, and [winning_dvc] below resolves an exact [(last_normal_view, n)] tie by keeping
   whichever candidate it saw first -- VSR.tla's own [CHOOSE] is likewise free to return any
   maximal element, so sorting does not narrow the spec, it just makes THIS implementation's choice
   reproducible across runs (and therefore testable). *)
let valid_dvcs t =
  Hashtbl.fold (fun _ d acc -> if valid_dvc t d then d :: acc else acc) t.recv_dvc []
  |> List.sort (fun a b -> compare a.dvc_i b.dvc_i)

(* ---- WinningDVC (VSR.tla:248-255) ----
   [CHOOSE] the valid DVC for which no other valid DVC has either a strictly greater
   [last_normal_view], or an equal [last_normal_view] and a strictly greater [n] -- i.e. the
   lexicographic maximum by [(last_normal_view, n)], [last_normal_view] FIRST (research §2.4 step 3:
   "selects as the new log the one contained in the message with the largest v'; if several messages
   have the same v' it selects the one among them with the largest n"). Selecting by [n] alone is a
   real safety bug, not a simplification: a replica that stayed in an OLDER view can have a longer
   log than the replica that was most recently normal in the NEWEST view, and adopting the longer
   log would discard the newer view's committed entries.

   The fold keeps the incumbent on ties (STRICT [>] in both comparisons), so with [valid_dvcs]'s
   sort above, an exact [(last_normal_view, n)] tie resolves to the lowest sender id. *)
let winning_dvc (dvcs : dvc list) =
  match dvcs with
  | [] -> None (* unreachable from [try_send_sv]: its own [>= f + 1] guard implies a non-empty list *)
  | first :: rest ->
    Some
      (List.fold_left
         (fun best d ->
           if
             d.dvc_last_normal_view > best.dvc_last_normal_view
             || (d.dvc_last_normal_view = best.dvc_last_normal_view && d.dvc_n > best.dvc_n)
           then d
           else best)
         first rest)

(* ---- HighestCommitNumber (VSR.tla:257-260) ----
   A SEPARATE, INDEPENDENT maximum of [m.k] over the valid DVCs -- deliberately NOT derived from
   [winning_dvc]'s own result. VSR.tla:244-245 warns about exactly this in its own comment ("§5.7's
   explicit warning that HighestCommitNumber is a SEPARATE maximum, not derived from the winning
   DVC"), and this plan's Global Constraints repeat it: a future reader diffing this code against
   the spec must find two clearly separate scans. The winning DVC (chosen by [(last_normal_view, n)])
   routinely is NOT the DVC with the highest [k].

   [0] is a correct identity for the fold rather than a floor that could mask a negative: every
   entry in [recv_dvc] has passed [handle_do_view_change]'s own [k < 0] rejection below, and
   VSR.tla's [rep_commit_number] is typed [Nat] (VSR.tla:25, 325). *)
let highest_commit_number (dvcs : dvc list) =
  List.fold_left (fun acc d -> if d.dvc_k > acc then d.dvc_k else acc) 0 dvcs

(* ---- SendSV (VSR.tla:264-280) ----
   Driven from [handle_do_view_change] ([ReceiveDVC]) below, mirroring [try_send_dvc]'s own
   established "drive the derived action from every point its enabling condition can change"
   pattern. Unlike [try_send_dvc], NO call is needed from [check_timeout] or
   [handle_start_view_change]: those two are the only other actions that touch anything this guard
   reads, and both set [recv_dvc] to EMPTY in the same step, so the threshold conjunct
   [Cardinality(valid recv_dvc) >= f + 1] is provably false immediately after either of them --
   [f + 1 >= 1 > 0] for EVERY [replica_count], including the degenerate [f = 0] cluster that made
   [try_send_dvc]'s own extra call worth including. That is a proof for all cluster sizes, not an
   "always a no-op in practice" assumption.

   Note the threshold is [>= f + 1] (VSR.tla:269), NOT [SendDVC]'s [>= f] (VSR.tla:221): "f+1
   DOVIEWCHANGE from different replicas, INCLUDING ITSELF" (VSR.tla:262-263) vs. "f STARTVIEWCHANGE
   from OTHER replicas" (VSR.tla:207). The two are kept as two textually separate expressions, each
   citing its own spec line, per this plan's Global Constraints -- deliberately not factored into
   one shared constant that a later edit could drift. *)
let try_send_sv t =
  let f = (t.replica_count - 1) / 2 in
  let dvcs = valid_dvcs t in
  if t.status = View_change (* VSR.tla:267 *) && is_primary t (* VSR.tla:268: r = Primary(View(r)) *)
     && List.length dvcs >= f + 1 (* VSR.tla:269 *)
  then
    match winning_dvc dvcs with
    | None -> () (* unreachable, see [winning_dvc] *)
    | Some winner ->
      let new_k = highest_commit_number dvcs in
      if new_k > winner.dvc_n then
        () (* DEFENSIVE, NOT IN VSR.tla -- and inert for every correct execution the model can
              reach. The two independent maxima above disagree here in a way no well-formed DVC set
              can produce: some valid DVC claims a commit_number beyond the END of the log this
              view is about to adopt. Applying it would set [commit_number > op_number] on the new
              primary and then broadcast that same [k] cluster-wide in [StartView], violating
              [CommitNumberNeverHigherThanOpNumber] (VSR.tla:330-331) on every replica that accepts
              it. Since each individual DVC is already field-validated on arrival (see
              [handle_do_view_change]), reaching this branch means at least one DVC in the set is
              corrupt/forged in a way only CROSS-message comparison can expose, and there is no way
              to tell which -- so the whole action is refused, no state changes at all (this
              module's established "guard failure => total no-op" convention), rather than
              inventing a bounded substitute. Deliberately NOT a clamp to [winner.dvc_n]: that
              targets the maximum legal value, i.e. it would declare the entire adopted log
              committed off the back of one corrupted integer -- exactly the reasoning
              [handle_prepare]'s own [k] bound already rejects clamping for. Cost of refusing is
              liveness only, and bounded: [recv_dvc] is wiped at the start of the next view-change
              episode. EVIDENCE this never fires for well-formed traffic: a scratch copy of
              spec/tla/VSR.tla with the invariant [T3_SendSvCommitWithinWinnerLog] (SendSV enabled
              => HighestCommitNumber(r) <= WinningDVC(r).n) was TLC-checked over the shipped
              VSR.cfg bound -- no violation, 553,084 states generated / 264,376 distinct / 0 left
              on queue, the same exhaustive state graph spec/tla/README.md quotes; a companion
              vacuity check ([SendSV] is never enabled) IS violated, confirming the invariant was
              exercised against real states rather than passing vacuously. *)
      else begin
        (* VSR.tla:272-273: [rep_log' = winner.log] and [rep_op_number' = winner.n]. This module
           tracks op_number AS the log's own length (see [op_number] above), so the second
           assignment is not separate code -- it is implied by the first, and is correct ONLY
           because [handle_do_view_change] rejects any DVC whose [n] disagrees with its own log's
           length. That check is what keeps VSR.tla's [LogLengthMatchesOpNumber] (VSR.tla:337-338)
           true by construction here for adversarial input too, not just well-formed input. *)
        Replica_log.replace_with t.log winner.dvc_log;
        t.commit_number <- new_k;
        (* VSR.tla:274 -- unconditional, NOT monotonic-guarded: unlike [ReceiveSV]'s own update,
           this replica is the one STARTING the new view, and [new_k] is the maximum over a
           quorum's worth of DVCs including (normally) its own. *)
        t.last_normal_view <- t.view_number (* VSR.tla:276 *);
        t.svc_count <- 0
        (* Disclosed divergence -- see [svc_count]'s own doc comment on [t]. Unconditional here
           because VSR.tla:267's own guard already restricts this action to [status = View_change],
           so reaching this point IS a real View_change -> Normal transition. *);
        t.status <- Normal (* VSR.tla:275 *);
        let bytes =
          Message.encode (Message.Start_view { v = t.view_number; log = winner.dvc_log; n = winner.dvc_n; k = new_k })
        in
        (* VSR.tla:277-278's own [Broadcast(..., r)] -- every OTHER replica, never self (VSR.tla:56's
           [replicas \ {source}]), exactly like [propose]'s and [check_timeout]'s broadcasts. *)
        for peer = 1 to t.replica_count do
          if peer <> t.my_id then t.send ~to_:peer bytes
        done
      end

(* ---- ReceiveDVC (VSR.tla:232-240) ----
   Guard: [ValidDvc(r, m)] and nothing else -- in particular NO status conjunct (a DVC matching this
   replica's current view is accumulated even while [status = Normal], exactly as in the spec; the
   sole reader, [try_send_sv], carries the [status = View_change] check instead) and no
   [r = Primary(View(r))] conjunct (VSR.tla relies on [m.dest] for that; a misrouted DVC simply
   accumulates on a non-primary, where nothing ever reads it).

   Every integer field is validated before being trusted, matching the precedent already
   established twice in this module ([handle_prepare_ok]'s [i]/[n], [handle_prepare]'s [k]):
   [Message.decode] confirms a message's SHAPE, never its protocol-level legality, and
   {!Riptide_transport.Transport_intf.S} promises no payload integrity. Each check below is
   accompanied by the property of the sending replica it re-establishes, and each was confirmed
   INERT for correct traffic by TLC on a scratch copy of spec/tla/VSR.tla (invariant
   [T3_DvcFieldsWellFormed]: every DoViewChange record in the message bag satisfies
   [Len(m.log) = m.n /\ m.k <= m.n /\ m.last_normal_view < m.v /\ m.i \in replicas]) -- no
   violation over the full 264,376-distinct-state graph, with a companion vacuity check confirming
   DoViewChange messages really do occur there. *)
let handle_do_view_change t ~(v : int) ~(log : Value.value list) ~(last_normal_view : int) ~(n : int) ~(k : int)
    ~(i : int) =
  if i < 1 || i > t.replica_count then
    () (* VSR.tla:15's own [replicas == 1..ReplicaCount]. Note this check does NOT exclude
          [i = t.my_id], unlike [handle_start_view_change]'s otherwise-identical-looking check: a
          DOVIEWCHANGE from this replica to itself is entirely legitimate and REQUIRED -- VSR.tla:224
          addresses it to [Primary(View(r))], which is this replica whenever it is the new primary,
          and VSR.tla:262-263's quorum is "f+1 ... from different replicas, INCLUDING ITSELF".
          Excluding self here would make [SendSV] need f+1 OTHER replicas, i.e. a strictly larger
          quorum than the protocol specifies, and would stall every view change in a cluster with
          exactly f+1 survivors. *)
  else if v <> t.view_number then
    () (* ValidDvc(r, m) == m.v = View(r) (VSR.tla:230, 235) -- a DVC for any other view, higher or
          lower, is matched by no action and dropped. For a HIGHER view this is a deliberate,
          already-analyzed liveness simplification, not an oversight (spec/tla/README.md's own
          known-simplifications list, and VSR.tla:176-182's own scope note): a DOVIEWCHANGE is
          unicast, so any view it could announce was already broadcast to everyone as a
          STARTVIEWCHANGE first. *)
  else if n < 0 || n <> List.length log then
    () (* [n] must be exactly the length of the log the same message carries -- VSR.tla's own
          [LogLengthMatchesOpNumber] (VSR.tla:337-338) applied to the sender's state, since
          [SendDVC] builds [log] and [n] from [rep_log[r]] and [rep_op_number[r]] in one step
          (VSR.tla:222-223). Load-bearing rather than cosmetic: [try_send_sv] adopts [winner.log]
          and relies on the resulting log length BEING [winner.n] (this module has no separate
          op_number field to assign), and [StartView.n] is then broadcast cluster-wide. *)
  else if k < 0 || k > n then
    () (* [CommitNumberNeverHigherThanOpNumber] (VSR.tla:330-331) applied to the sender's own state.
          Note [<=], not [<], is the right bound HERE, unlike [handle_prepare]'s [k < n]: a DVC's
          [k] and [n] are the sender's own commit_number and op_number, which legitimately coincide
          on a fully-committed replica, whereas a Prepare's [k] is the primary's commit_number from
          strictly before the entry that same message carries. This is the single field
          [HighestCommitNumber] maximizes over, so an unbounded [k] here is the most direct route to
          a cluster-wide [CommitNumberNeverHigherThanOpNumber] violation via [StartView.k]. *)
  else if last_normal_view < 0 || last_normal_view >= v then
    () (* [last_normal_view] is the PRIMARY sort key [WinningDVC] selects the surviving log by, so an
          unbounded value here lets one forged DVC dictate the entire cluster's log -- the most
          safety-critical field on this message type. A correct sender's [last_normal_view] is
          always STRICTLY below the view its DOVIEWCHANGE announces: [SendDVC] requires
          [status = "ViewChange"] (VSR.tla:219), [last_normal_view] is only ever written by
          [SendSV]/[ReceiveSV] (which set [status = "Normal"] in the same step, VSR.tla:275-276,
          301-302), and both actions that ENTER "ViewChange" raise [view_number] strictly above the
          replica's current view without touching [last_normal_view] (VSR.tla:166-167, 187-188).
          Confirmed exhaustively rather than argued: TLC on a scratch copy of VSR.tla with
          [T3_ViewChangeImpliesLastNormalViewBelowView] ([status = "ViewChange" =>
          last_normal_view < view_number]) found no violation across all 264,376 distinct reachable
          states, and the matching [T3_DvcFieldsWellFormed] conjunct checks the property on the
          DOVIEWCHANGE records themselves. *)
  else begin
    let d =
      { dvc_v = v; dvc_log = log; dvc_last_normal_view = last_normal_view; dvc_n = n; dvc_k = k; dvc_i = i }
    in
    (* FIRST-WINS, per sender, per EPISODE -- see [recv_dvc]'s own doc comment on [t] for the full
       reasoning. [already_this_episode] deliberately checks the stored entry's own [dvc_v] rather
       than mere key presence: an entry left over from an older view (only reachable via
       [handle_start_view], the one action that raises [view_number] without clearing this table)
       belongs to no current episode and must not shadow a genuinely current DVC from the same
       sender. That shadowing would in fact be harmless today -- any entry present while
       [status = Normal] is wiped by whichever action next enters [View_change], before
       [try_send_sv] can read it -- but the check costs one comparison and removes the need for a
       future reader to re-derive that argument. *)
    let already_this_episode =
      match Hashtbl.find_opt t.recv_dvc i with Some existing -> existing.dvc_v = t.view_number | None -> false
    in
    if not already_this_episode then begin
      Hashtbl.replace t.recv_dvc i d (* VSR.tla:236's own [@ \cup {m}], keyed by sender *);
      try_send_sv t
      (* [ReceiveDVC] is the ONLY action that raises [Cardinality({valid DVCs})], so this is the
         only point [SendSV]'s threshold can newly become satisfied -- see [try_send_sv]'s own
         comment for why no other call site is needed. Deliberately inside this branch: an ignored
         duplicate changes nothing the guard reads. *)
    end
  end

(* ---- ReceiveSV (VSR.tla:292-305) ---- *)
let handle_start_view t ~(v : int) ~(log : Value.value list) ~(n : int) ~(k : int) =
  if v < 0 then () (* [rep_view_number] is typed [Nat] (VSR.tla:30, 326) *)
  else if v < t.view_number then
    () (* VSR.tla:295's own guard is [m.v >= View(r)] -- [>=], NOT [>]: a StartView for the view
          this replica is ALREADY in is accepted and re-applied (that is what makes the conditional
          [svc_count] reset below necessary, per task-3-brief.md's resolved decision 3). Only a
          strictly LOWER view is dropped. There is deliberately no status conjunct either. *)
  else if n < 0 || n <> List.length log then
    () (* Same [LogLengthMatchesOpNumber] check, same reason, as [handle_do_view_change]'s: this
          log is adopted wholesale and its length BECOMES this replica's op_number. TLC-confirmed
          inert for correct traffic ([T3_SvFieldsWellFormed]). *)
  else if k < 0 || k > n then
    () (* [CommitNumberNeverHigherThanOpNumber] for the state this message is asking us to adopt:
          [k] is the new primary's [HighestCommitNumber] and [n] the winning log's length. *)
  else if n < t.commit_number then
    () (* DEFENSIVE, NOT IN VSR.tla, and inert for every correct execution the model can reach:
          refuse a StartView whose log is SHORTER than what this replica has already committed.
          Adopting it would discard committed entries outright (real data loss, and it would leave
          [commit_number > op_number] here the moment the monotonic update below keeps our own
          higher value). EVIDENCE: TLC on a scratch copy of VSR.tla with
          [T3_ReceiveSvNeverTruncatesBelowCommit] (ReceiveSV enabled => [m.n >= rep_commit_number[r]])
          found no violation across the full 264,376-distinct-state graph, with a companion vacuity
          check confirming receivable StartViews with [m.v >= View(r)] really do occur. So this
          rejects nothing a correct primary ever sends -- it is purely a bound on forged/corrupted
          input. Dropped WHOLESALE (view_number/status untouched), per this module's "guard failure
          => total no-op" convention. *)
  else begin
    Replica_log.replace_with t.log log (* VSR.tla:296-297: log and op_number adopted wholesale *);
    if k > t.commit_number then t.commit_number <- k;
    (* VSR.tla:298-299's own [IF m.k > @ THEN m.k ELSE @] -- MONOTONIC ONLY. research §5.7 Part 4:
       applying [m.k] unconditionally is a REAL, documented defect (it caused a
       double-application-of-an-operation bug in the original published spec). Do not simplify this
       back to an unconditional assignment. The [k <= n] bound checked above is what keeps the
       result [<= op_number] in the OTHER direction, for a forged [k]. *)
    t.view_number <- v (* VSR.tla:300 *);
    t.last_normal_view <- v (* VSR.tla:302 *);
    if t.status = View_change then t.svc_count <- 0;
    (* Disclosed divergence (see [svc_count]'s doc comment on [t]), and CONDITIONAL here on a real
       View_change -> Normal transition -- task-3-brief.md's resolved decision 3. VSR.tla:295's
       guard has no status conjunct, so this action genuinely fires on a duplicated/replayed
       StartView for a view this replica is already Normal in; an unconditional reset would let such
       duplicates refresh the timeout budget indefinitely and quietly nullify [svc_limit]. Must be
       read BEFORE the [status <- Normal] write below. *)
    t.status <- Normal (* VSR.tla:301 *)
    (* [recv_dvc] and [recv_svc] are deliberately NOT reset -- VSR.tla:304 lists both as UNCHANGED,
       and spec/tla/README.md ("What the ValidDvc filter is actually doing here") has the detailed,
       TLC-backed argument for why the stale entries this genuinely leaves behind can never be READ:
       every reader is gated on [status = View_change], and both actions that reach that status
       ([check_timeout], [handle_start_view_change]'s higher-view branch) reset both structures
       first. Adding a reset here would deviate from the model this code is required to match, in a
       direction the model was never checked against. Do not "fix" it. *)
  end

let handle_message t (bytes : string) =
  match Message.decode bytes with
  | exception Message.Malformed_message _ -> ()
  | Message.Prepare { view; n; v; k } -> handle_prepare t ~view ~n ~v ~k
  | Message.Prepare_ok { view; n; i } -> handle_prepare_ok t ~view ~n ~i
  | Message.Start_view_change { v; i } -> handle_start_view_change t ~v ~i
  | Message.Do_view_change { v; log; last_normal_view; n; k; i } ->
    handle_do_view_change t ~v ~log ~last_normal_view ~n ~k ~i
  | Message.Start_view { v; log; n; k } -> handle_start_view t ~v ~log ~n ~k

(* ---- Test-support surface (continued): read-only views of the two view-change accumulators ----
   [recv_dvc]/[recv_svc] are private, and the protocol itself never needs to expose them -- but
   several properties this module is REQUIRED to hold are stated directly about them and are
   otherwise only observable indirectly, through whether a message eventually gets sent:
   [ReceiveSV]'s deliberate NON-reset of both (VSR.tla:304), the per-episode reset performed by
   [check_timeout]/[ReceiveHigherSVC] (VSR.tla:169, 190), and [recv_dvc]'s sender-keyed first-wins
   dedup. Both return sorted sender ids so a test can assert on an exact list. *)
let for_test_recv_dvc_senders t = Hashtbl.fold (fun i _ acc -> i :: acc) t.recv_dvc [] |> List.sort compare
let for_test_recv_svc_senders t = Int_set.elements t.recv_svc
