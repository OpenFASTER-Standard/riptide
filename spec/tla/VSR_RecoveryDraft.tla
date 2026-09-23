---- MODULE VSR_RecoveryDraft ----
(* THROWAWAY DRAFT -- finiteness probe only (plan task 4). NOT the real storage-fault-aware
   recovery extension; that is task 5, and it should be written fresh against whatever this
   probe finds, not grown out of this file.

   This module is a verbatim COPY of VSR.tla (as of the commit that added this file) plus a
   deliberately minimal sketch of storage-fault-aware recovery state and actions. It is a copy
   rather than an in-place edit of VSR.tla for one reason: spec/tla/README.md quotes
   `scripts/tlc VSR`'s own exhaustive result verbatim (553084 states generated, 264376 distinct,
   0 left on queue, 23s) as this branch's reproducible evidence. Adding variables to VSR.tla
   would change those numbers and silently falsify a committed, checkable claim. VSR.tla is
   therefore left byte-identical, and this draft carries the churn.

   What is sketched here, and only this (design already settled by
   docs/superpowers/specs/2026-09-23-storage-fault-tolerant-recovery-design.md, Decisions 4-5 --
   not re-derived):
     - Decision 5: per-replica, per-op tri-state storage abstraction {present, absent, corrupt},
       NOT a faithful two-ring WAL model.
     - Decision 4: nack evidence piggybacked on the existing DOVIEWCHANGE, plus a standalone
       out-of-band nack message, sketching a multi-step, interruptible view-change completion --
       NOT a separate CTRL round-trip protocol.
     - research §4.2/§4.8-§4.10 (as catalogued in spec/tla/README.md): the "never nack a corrupt
       entry" rule -- only a provably-absent op may be nacked.
   What is deliberately NOT here: any use of the accumulated nacks (no nack-quorum-driven log
   truncation, no "forfeit" escape, no durable view/log_view, no recovery of a corrupt entry),
   no new safety invariants, no wiring into VSR.tla's own invariant set. The accumulation
   actions exist purely so there is something of the right SHAPE to probe for finiteness. *)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS ReplicaCount, Values, StartViewOnTimerLimit, MaxOp, FaultLimit

replicas == 1..ReplicaCount

(* research §1.1: Primary is a pure function of the view number, never elected. *)
Primary(v) == 1 + ((v-1) % ReplicaCount)

ValuesSymmetry == Permutations(Values)

VARIABLES
    rep_log,               \* [replica -> Seq(Values)]
    rep_op_number,         \* [replica -> Nat]
    rep_commit_number,     \* [replica -> Nat]
    rep_peer_op_number,    \* [replica -> [replica -> Nat]] -- primary's view of each peer's ack'd op-number
    messages,              \* bag: message record -> pending delivery count
    aux_client_acked,      \* [Values -> BOOLEAN], set true once the primary executes+would reply
    rep_status,             \* [replica -> {"Normal", "ViewChange"}]
    rep_view_number,        \* [replica -> Nat]
    rep_last_normal_view,   \* [replica -> Nat] -- the paper's v', research §1.2: NOT derivable
                            \* from rep_view_number, an omission in the paper's own Figure 2
    rep_recv_svc,           \* [replica -> SUBSET replicas] -- STARTVIEWCHANGE senders for current view
    rep_recv_dvc,           \* [replica -> SUBSET [message]] -- DOVIEWCHANGE messages received
    rep_sent_dvc,           \* [replica -> BOOLEAN] -- TRUE once this replica has sent its
                            \* DOVIEWCHANGE for the CURRENT view-change episode; cleared
                            \* whenever a new episode starts. Without it SendDVC re-enables
                            \* itself forever (nothing it reads changes when it fires), each
                            \* firing producing a distinct state that differs only in the
                            \* message bag's count -- an infinite reachable state space.
    aux_svc_count,          \* [replica -> Nat] -- bounds TimerSendSVC, research §6.3 point 4
    (* ---- DRAFT recovery state (task 4 sketch only) ---- *)
    rep_storage,            \* [replica -> [1..MaxOp -> {"present","absent","corrupt"}]]
                            \* Decision 5's tri-state abstraction. Finite by construction.
    rep_recv_nacks,         \* [replica -> [1..MaxOp -> SUBSET replicas]] -- nack evidence a
                            \* view-change coordinator has accumulated, per op. Finite by
                            \* construction (a set of replicas, not a counter or a bag).
    rep_sent_nack           \* [replica -> [1..MaxOp -> BOOLEAN]] -- one-shot per (replica, op)
                            \* per view-change episode. NOT protocol logic: a modeling device,
                            \* added only after the finiteness probe caught SendNack
                            \* self-looping (see SendNack's own comment for the trace).

vars == << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number, messages,
            aux_client_acked, rep_status, rep_view_number, rep_last_normal_view,
            rep_recv_svc, rep_recv_dvc, rep_sent_dvc, aux_svc_count,
            rep_storage, rep_recv_nacks, rep_sent_nack >>

(* Convenience tuple so every pre-existing (non-recovery) action can leave the draft state
   untouched with one clause instead of four, keeping this copy's diff against VSR.tla small
   and reviewable. *)
draft_vars == << rep_storage, rep_recv_nacks, rep_sent_nack >>

ops == 1..MaxOp

View(r) == rep_view_number[r]
IsNormalPrimary(r) == /\ rep_status[r] = "Normal" /\ Primary(View(r)) = r
IsNormalBackup(r)   == /\ rep_status[r] = "Normal" /\ Primary(View(r)) # r

(* ---- message bag (research §5.3, verbatim technique) ---- *)
SendFunc(m, msgs) ==
    IF m \in DOMAIN msgs THEN [msgs EXCEPT ![m] = @ + 1] ELSE msgs @@ (m :> 1)

BroadcastFunc(msg, source, msgs) ==
    LET bcast_msgs == { [msg EXCEPT !.dest = r] : r \in replicas \ {source} }
        new_msgs   == bcast_msgs \ DOMAIN msgs
    IN [m \in DOMAIN msgs |-> IF m \in bcast_msgs THEN msgs[m] + 1 ELSE msgs[m]]
        @@ [r \in new_msgs |-> 1]

DiscardFunc(m, msgs) == [msgs EXCEPT ![m] = @ - 1]

Send(m) == messages' = SendFunc(m, messages)
Broadcast(msg, source) == messages' = BroadcastFunc(msg, source, messages)
Discard(m) == messages' = DiscardFunc(m, messages)
DiscardAndSend(d, s) == messages' = SendFunc(s, DiscardFunc(d, messages))

ReceivableMsg(m, type, r) == /\ m.type = type /\ m.dest = r /\ messages[m] > 0

(* Storage faults are chosen ONCE, in the initial state, rather than injected by an action.
   This is the probe's own second finding, not an aesthetic choice -- see the header note and
   the task-4 report. An InjectStorageFault action is enabled in EVERY reachable state, so it
   does not add states, it MULTIPLIES the whole base state graph by every distinct point at
   which a fault could first appear; that version of this draft was still expanding at 8.0M
   distinct states after 12 minutes. Nothing about the safety question being asked depends on
   a fault interleaving with consensus steps at a particular moment -- only on a replica HAVING
   a faulted op while it participates in a view change -- so the fault becomes an initial-state
   choice. At ReplicaCount=3, MaxOp=1, FaultLimit=1 this is 7 initial states (all-present, plus
   one of {absent, corrupt} at one of 3 replicas). *)
FaultConfigs ==
    { s \in [replicas -> [ops -> {"present", "absent", "corrupt"}]] :
        Cardinality({ ro \in replicas \X ops : s[ro[1]][ro[2]] # "present" }) <= FaultLimit }

(* ---- Init ---- *)
Init ==
    /\ rep_log = [r \in replicas |-> <<>>]
    /\ rep_op_number = [r \in replicas |-> 0]
    /\ rep_commit_number = [r \in replicas |-> 0]
    /\ rep_peer_op_number = [r \in replicas |-> [p \in replicas |-> 0]]
    /\ messages = <<>>
    /\ aux_client_acked = [v \in Values |-> FALSE]
    /\ rep_status = [r \in replicas |-> "Normal"]
    /\ rep_view_number = [r \in replicas |-> 0]
    /\ rep_last_normal_view = [r \in replicas |-> 0]
    /\ rep_recv_svc = [r \in replicas |-> {}]
    /\ rep_recv_dvc = [r \in replicas |-> {}]
    /\ rep_sent_dvc = [r \in replicas |-> FALSE]
    /\ aux_svc_count = [r \in replicas |-> 0]
    /\ rep_storage \in FaultConfigs
    /\ rep_recv_nacks = [r \in replicas |-> [o \in ops |-> {}]]
    /\ rep_sent_nack = [r \in replicas |-> [o \in ops |-> FALSE]]

(* ---- DRAFT recovery helpers (task 4 sketch) ----
   research §4.2, §4.8-§4.10 as catalogued in spec/tla/README.md: the "never nack a corrupt
   entry" rule. A replica may nack an op only when it can prove it never durably held it
   ("absent"). A "corrupt" op is precisely the case where it CANNOT prove that -- the entry may
   have been present and been lost -- so nacking it could let a quorum jointly "prove" that a
   committed op was never held, discarding committed data. That asymmetry is the whole point of
   the tri-state abstraction over a boolean present/missing one. *)
CanNack(r, o) == rep_storage[r][o] = "absent"

NackSet(r) == { o \in ops : CanNack(r, o) }

(* ---- normal-case actions, research §1.4 steps 1-7 (generalized to the current primary of
   whatever view is active, with the view-match precondition from research §1.5 point 3:
   "Replicas only process normal protocol messages containing a view-number that matches the
   view-number they know") ---- *)

ReceiveClientRequest(v) ==
    \E r \in replicas :
        /\ IsNormalPrimary(r)
        /\ v \notin { rep_log[r][i] : i \in DOMAIN rep_log[r] }
        /\ LET n == rep_op_number[r] + 1
           IN /\ rep_log' = [rep_log EXCEPT ![r] = Append(@, v)]
              /\ rep_op_number' = [rep_op_number EXCEPT ![r] = n]
              /\ Broadcast([type |-> "Prepare", view |-> View(r), n |-> n, v |-> v,
                            k |-> rep_commit_number[r], dest |-> r], r)
    /\ UNCHANGED << rep_commit_number, rep_peer_op_number, aux_client_acked, rep_status,
                    rep_view_number, rep_last_normal_view, rep_recv_svc, rep_recv_dvc,
                    rep_sent_dvc, aux_svc_count >>

(* research §1.5 point 7: backups process PREPARE strictly in op-number order.
   research §1.4 step 7: a backup advances its commit-number to m.k whenever higher --
   safe unconditionally: a normal PREPARE's k is always the primary's commit-number from
   before the request carried by this same message was appended (m.k < m.n), and by the time
   a backup processes this message its own rep_op_number has just been set to m.n, so every
   entry up to m.k is already guaranteed present in its log. *)
ReceivePrepareMsg ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ IsNormalBackup(r)
        /\ ReceivableMsg(m, "Prepare", r)
        /\ m.view = View(r)
        /\ rep_op_number[r] + 1 = m.n
        /\ rep_log' = [rep_log EXCEPT ![r] = Append(@, m.v)]
        /\ rep_op_number' = [rep_op_number EXCEPT ![r] = m.n]
        /\ rep_commit_number' = [rep_commit_number EXCEPT ![r] = IF m.k > @ THEN m.k ELSE @]
        /\ DiscardAndSend(m, [type |-> "PrepareOk", view |-> View(r), n |-> m.n, i |-> r,
                              dest |-> Primary(View(r))])
        /\ UNCHANGED << rep_peer_op_number, aux_client_acked, rep_status,
                        rep_view_number, rep_last_normal_view, rep_recv_svc, rep_recv_dvc,
                        rep_sent_dvc, aux_svc_count >>

(* research §1.5 point 2: PREPAREOK is cumulative, so peer state is a single high-water mark. *)
ReceivePrepareOkMsg ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ IsNormalPrimary(r)
        /\ ReceivableMsg(m, "PrepareOk", r)
        /\ m.view = View(r)
        /\ rep_peer_op_number' = [rep_peer_op_number EXCEPT ![r][m.i] =
                                    IF m.n > @ THEN m.n ELSE @]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, aux_client_acked, rep_status,
                        rep_view_number, rep_last_normal_view, rep_recv_svc, rep_recv_dvc,
                        rep_sent_dvc, aux_svc_count >>

(* research §1.5 point 1: f PREPAREOKs from OTHER replicas = f+1 counting the primary itself. *)
IsCommitted(r, op_number) ==
    LET f == (ReplicaCount - 1) \div 2   \* 2f+1 = ReplicaCount
        acked_backups == Cardinality({ p \in replicas \ {r} :
                                        rep_peer_op_number[r][p] >= op_number })
    IN acked_backups >= f

PrimaryExecuteOp ==
    \E r \in replicas :
        /\ IsNormalPrimary(r)
        /\ rep_commit_number[r] < rep_op_number[r]
        /\ LET next == rep_commit_number[r] + 1
           IN /\ IsCommitted(r, next)
              /\ rep_commit_number' = [rep_commit_number EXCEPT ![r] = next]
              /\ aux_client_acked' = [aux_client_acked EXCEPT ![rep_log[r][next]] = TRUE]
    /\ UNCHANGED << rep_log, rep_op_number, rep_peer_op_number, messages, rep_status,
                    rep_view_number, rep_last_normal_view, rep_recv_svc, rep_recv_dvc,
                    rep_sent_dvc, aux_svc_count >>

(* ---- view-change actions, research §2.1, §2.4-§2.5 ----
   research §2.1: do not model real timeouts -- an unconditional, always-enabled action,
   bounded by a state-space-limiting counter. *)

TimerSendSVC ==
    \E r \in replicas :
        /\ aux_svc_count[r] < StartViewOnTimerLimit
        /\ rep_status[r] = "Normal"
        /\ LET v == View(r) + 1
           IN /\ rep_view_number' = [rep_view_number EXCEPT ![r] = v]
              /\ rep_status' = [rep_status EXCEPT ![r] = "ViewChange"]
              /\ rep_recv_svc' = [rep_recv_svc EXCEPT ![r] = {}]
              /\ rep_recv_dvc' = [rep_recv_dvc EXCEPT ![r] = {}]
              /\ rep_sent_dvc' = [rep_sent_dvc EXCEPT ![r] = FALSE]
              /\ aux_svc_count' = [aux_svc_count EXCEPT ![r] = @ + 1]
              /\ rep_recv_nacks' = [rep_recv_nacks EXCEPT ![r] = [o \in ops |-> {}]]
              /\ rep_sent_nack' = [rep_sent_nack EXCEPT ![r] = [o \in ops |-> FALSE]]
              /\ Broadcast([type |-> "StartViewChange", v |-> v, i |-> r, dest |-> r], r)
    /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                    aux_client_acked, rep_last_normal_view, rep_storage >>

(* research §2.4 step 1 (2nd half): a replica also starts a view change on a HIGHER-view
   message than its own -- assume-mode (research Global Constraints), not increment-mode.
   Scope note: only a higher-view STARTVIEWCHANGE triggers this here. There is deliberately no
   analogous action for a higher-view DOVIEWCHANGE -- ReceiveDVC is gated on ValidDvc, so a
   DOVIEWCHANGE carrying a higher view than the recipient's is matched by no action and stays
   in the bag. See spec/tla/README.md's known-simplifications list for why this is safe at
   this scope (it costs liveness, not safety). *)
ReceiveHigherSVC ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "StartViewChange", r)
        /\ m.v > View(r)
        /\ rep_view_number' = [rep_view_number EXCEPT ![r] = m.v]
        /\ rep_status' = [rep_status EXCEPT ![r] = "ViewChange"]
        /\ rep_recv_svc' = [rep_recv_svc EXCEPT ![r] = {m.i}]
        /\ rep_recv_dvc' = [rep_recv_dvc EXCEPT ![r] = {}]
        /\ rep_sent_dvc' = [rep_sent_dvc EXCEPT ![r] = FALSE]
        /\ rep_recv_nacks' = [rep_recv_nacks EXCEPT ![r] = [o \in ops |-> {}]]
        /\ rep_sent_nack' = [rep_sent_nack EXCEPT ![r] = [o \in ops |-> FALSE]]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_last_normal_view, aux_svc_count,
                        rep_storage >>

ReceiveMatchingSVC ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "StartViewChange", r)
        /\ m.v = View(r)
        /\ rep_status[r] = "ViewChange"
        /\ rep_recv_svc' = [rep_recv_svc EXCEPT ![r] = @ \cup {m.i}]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_view_number, rep_status, rep_last_normal_view,
                        rep_recv_dvc, rep_sent_dvc, aux_svc_count >>

(* research §2.4 step 2, §2.5: "f STARTVIEWCHANGE from other replicas".

   The rep_sent_dvc one-shot flag is a modeling device, not protocol logic: a replica sends its
   DOVIEWCHANGE once per view-change episode. Without it this action's own effect leaves every
   one of its guards true, so it re-enables itself indefinitely and each firing yields a distinct
   state (one more copy of the same message in the bag) -- an infinite reachable state space that
   no exhaustive TLC run at any bound can terminate on. The flag mirrors how aux_svc_count already
   bounds TimerSendSVC (research §6.3 point 4), and is cleared by both actions that begin a new
   view-change episode. *)
SendDVC ==
    \E r \in replicas :
        LET f == (ReplicaCount - 1) \div 2 IN
        /\ rep_status[r] = "ViewChange"
        /\ ~rep_sent_dvc[r]
        /\ Cardinality(rep_recv_svc[r]) >= f
        (* DRAFT, Decision 4: nack evidence is PIGGYBACKED on the existing DOVIEWCHANGE
           ("carrying nack information on the existing DoViewChange-equivalent message -- not a
           separate CTRL round-trip protocol"), as one extra field. *)
        /\ Send([type |-> "DoViewChange", v |-> View(r), log |-> rep_log[r],
                  last_normal_view |-> rep_last_normal_view[r], n |-> rep_op_number[r],
                  k |-> rep_commit_number[r], i |-> r, nacks |-> NackSet(r),
                  dest |-> Primary(View(r))])
        /\ rep_sent_dvc' = [rep_sent_dvc EXCEPT ![r] = TRUE]
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_view_number, rep_status, rep_last_normal_view,
                        rep_recv_svc, rep_recv_dvc, aux_svc_count,
                        rep_storage, rep_recv_nacks, rep_sent_nack >>

ValidDvc(r, m) == m.v = View(r)

ReceiveDVC ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "DoViewChange", r)
        /\ ValidDvc(r, m)
        /\ rep_recv_dvc' = [rep_recv_dvc EXCEPT ![r] = @ \cup {m}]
        (* DRAFT: accumulate the piggybacked nack evidence per op. Finite by construction --
           a set of replica ids, so it saturates at `replicas` and cannot grow past it. *)
        /\ rep_recv_nacks' = [rep_recv_nacks EXCEPT ![r] =
                                [o \in ops |-> IF o \in m.nacks THEN @[o] \cup {m.i} ELSE @[o]]]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_view_number, rep_status, rep_last_normal_view,
                        rep_recv_svc, rep_sent_dvc, aux_svc_count,
                        rep_storage, rep_sent_nack >>

(* research §2.4 step 3 ("selects as the new log the one contained in the message with the
   largest v'; if several messages have the same v' it selects the one among them with the
   largest n") and §5.7's explicit warning that HighestCommitNumber is a SEPARATE maximum, not
   derived from the winning DVC. Adapted directly (only variable-naming changes) from
   Vanlightly's own published, already-TLC-verified WinningDVC/SendSV (research §5.7, quoted
   verbatim there). *)
WinningDVC(r) ==
    CHOOSE m \in rep_recv_dvc[r] :
        /\ ValidDvc(r, m)
        /\ ~ \E m1 \in rep_recv_dvc[r] :
            /\ ValidDvc(r, m1)
            /\ \/ m1.last_normal_view > m.last_normal_view
               \/ /\ m1.last_normal_view = m.last_normal_view
                  /\ m1.n > m.n

HighestCommitNumber(r) ==
    LET valid_dvcs == { m \in rep_recv_dvc[r] : ValidDvc(r, m) }
    IN CHOOSE k \in { m.k : m \in valid_dvcs } :
        ~ \E m \in valid_dvcs : m.k > k

(* research §2.4 step 3 and §2.5 ("f+1 DOVIEWCHANGE from different replicas, including
   itself"). *)
SendSV ==
    \E r \in replicas :
        LET f == (ReplicaCount - 1) \div 2 IN
        /\ rep_status[r] = "ViewChange"
        /\ r = Primary(View(r))
        /\ Cardinality({ m \in rep_recv_dvc[r] : ValidDvc(r, m) }) >= f + 1
        /\ LET winner == WinningDVC(r)
               new_k == HighestCommitNumber(r)
           IN /\ rep_log' = [rep_log EXCEPT ![r] = winner.log]
              /\ rep_op_number' = [rep_op_number EXCEPT ![r] = winner.n]
              /\ rep_commit_number' = [rep_commit_number EXCEPT ![r] = new_k]
              /\ rep_status' = [rep_status EXCEPT ![r] = "Normal"]
              /\ rep_last_normal_view' = [rep_last_normal_view EXCEPT ![r] = View(r)]
              /\ Broadcast([type |-> "StartView", v |-> View(r), log |-> winner.log,
                            n |-> winner.n, k |-> new_k, dest |-> r], r)
        /\ UNCHANGED << rep_peer_op_number, aux_client_acked, rep_view_number,
                        rep_recv_svc, rep_recv_dvc, rep_sent_dvc, aux_svc_count >>

(* research §2.4 step 5 (simplified for this spec's scope: skip re-sending PREPAREOK for
   uncommitted entries, since that requires the primary to re-track post-view-change acks --
   out of scope here, and disclosed in spec/tla/README.md as a known simplification, not a
   silent omission).

   Note the "IF m.k > @ THEN m.k ELSE @" guard on rep_commit_number -- this is research §5.7
   Part 4's documented commit-number-monotonicity fix ("the fix is to ensure that the
   commit-number is only updated if the [message]'s commit-number is higher"). Applying m.k
   unconditionally is a REAL, documented defect (it caused a double-application-of-an-operation
   bug in Vanlightly's own spec) -- do not simplify this back to unconditional assignment. *)
ReceiveSV ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "StartView", r)
        /\ m.v >= View(r)
        /\ rep_log' = [rep_log EXCEPT ![r] = m.log]
        /\ rep_op_number' = [rep_op_number EXCEPT ![r] = m.n]
        /\ rep_commit_number' = [rep_commit_number EXCEPT ![r] =
                                    IF m.k > @ THEN m.k ELSE @]  \* research §5.7 Part 4: monotonic only
        /\ rep_view_number' = [rep_view_number EXCEPT ![r] = m.v]
        /\ rep_status' = [rep_status EXCEPT ![r] = "Normal"]
        /\ rep_last_normal_view' = [rep_last_normal_view EXCEPT ![r] = m.v]
        /\ Discard(m)
        /\ UNCHANGED << rep_peer_op_number, aux_client_acked, rep_recv_svc, rep_recv_dvc,
                        rep_sent_dvc, aux_svc_count >>

(* ================= DRAFT storage-fault-aware recovery actions (task 4 sketch) =================
   Three actions only. Everything else this piece eventually needs (nack-quorum-driven
   truncation, the "forfeit" escape, durable view/log_view, repair/state-transfer) is task 5's
   and is deliberately absent -- the point here is to have accumulation-shaped actions to probe,
   not a working protocol. *)

(* Decision 4's "multi-step, interruptible" half: a replica that discovers a provably-absent op
   AFTER its own DOVIEWCHANGE already went out must still be able to get that evidence to the
   coordinator, otherwise the piggyback channel alone would make the sequence atomic again --
   exactly what Decision 4 says storage-fault-awareness forbids. So: an out-of-band NACK to the
   coordinator of the current view.

   THE FINITENESS PROBE'S ACTUAL FINDING. Drafted first WITHOUT the rep_sent_nack guard below --
   i.e. guards `rep_status[r] = "ViewChange"` and `CanNack(r, o)` only. Neither is falsified by
   the action's own effect (storage faults never repair, and sending a message does not end a
   view change), and the sole effect is a message-bag increment, so the action re-enabled itself
   forever, each firing a distinct state. Infinite reachable state space. NoUnboundedGrowth
   caught it at depth 6 in under a second, with a trace of three consecutive SendNack steps
   driving one bag entry's count 1 -> 2 -> 3. This is the SendDVC defect exactly, reproduced in
   the very action class spec/tla/README.md predicted would reproduce it.

   The fix mirrors rep_sent_dvc verbatim: one shot per (replica, op) per view-change episode,
   cleared by both actions that begin a new episode. It is a modeling device, not protocol
   logic -- a real implementation retransmits, and task 5 must bound that retransmission
   explicitly rather than inherit this flag as though it were a design. *)
SendNack ==
    \E r \in replicas, o \in ops :
        /\ rep_status[r] = "ViewChange"
        /\ CanNack(r, o)
        /\ ~rep_sent_nack[r][o]
        /\ Send([type |-> "Nack", v |-> View(r), op |-> o, i |-> r,
                  dest |-> Primary(View(r))])
        /\ rep_sent_nack' = [rep_sent_nack EXCEPT ![r][o] = TRUE]
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_status, rep_view_number, rep_last_normal_view,
                        rep_recv_svc, rep_recv_dvc, rep_sent_dvc, aux_svc_count,
                        rep_storage, rep_recv_nacks >>

ReceiveNack ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "Nack", r)
        /\ m.v = View(r)
        /\ rep_recv_nacks' = [rep_recv_nacks EXCEPT ![r][m.op] = @ \cup {m.i}]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_status, rep_view_number, rep_last_normal_view,
                        rep_recv_svc, rep_recv_dvc, rep_sent_dvc, aux_svc_count,
                        rep_storage, rep_sent_nack >>

(* The 7 pre-existing actions that touch no draft state keep VSR.tla's own definitions verbatim
   and are made to leave draft_vars untouched here, at the disjunction, rather than by editing 7
   UNCHANGED tuples in place -- keeping this copy's diff against VSR.tla small enough to review
   by eye. The 4 that DO touch draft state (TimerSendSVC, ReceiveHigherSVC, SendDVC, ReceiveDVC)
   are edited in place instead and are excluded from the blanket clause. *)
Next ==
    \/ (\E v \in Values : ReceiveClientRequest(v)) /\ UNCHANGED draft_vars
    \/ ReceivePrepareMsg /\ UNCHANGED draft_vars
    \/ ReceivePrepareOkMsg /\ UNCHANGED draft_vars
    \/ PrimaryExecuteOp /\ UNCHANGED draft_vars
    \/ TimerSendSVC
    \/ ReceiveHigherSVC
    \/ ReceiveMatchingSVC /\ UNCHANGED draft_vars
    \/ SendDVC
    \/ ReceiveDVC
    \/ SendSV /\ UNCHANGED draft_vars
    \/ ReceiveSV /\ UNCHANGED draft_vars
    \/ SendNack
    \/ ReceiveNack

Spec == Init /\ [][Next]_vars

(* ---- safety invariants ---- *)
TypeOK ==
    /\ \A r \in replicas : rep_op_number[r] \in Nat
    /\ \A r \in replicas : rep_commit_number[r] \in Nat
    /\ \A r \in replicas : rep_view_number[r] \in Nat
    /\ \A r \in replicas : rep_status[r] \in {"Normal", "ViewChange"}
    /\ \A r \in replicas : rep_sent_dvc[r] \in BOOLEAN

CommitNumberNeverHigherThanOpNumber ==
    \A r \in replicas : rep_commit_number[r] <= rep_op_number[r]

(* The structural relationship NoLogDivergence implicitly relies on: it indexes
   rep_log[r][op_number] guarded only by op_number <= rep_commit_number[r], which is
   in-domain only because the log's length tracks the op-number exactly. Asserted
   explicitly rather than assumed. *)
LogLengthMatchesOpNumber ==
    \A r \in replicas : Len(rep_log[r]) = rep_op_number[r]

(* README.md, "What the ValidDvc filter is actually doing here": rep_recv_dvc[r] can carry stale
   (no-longer-valid) entries forward across a view bump that ReceiveSV performs without clearing
   it, but only while rep_status[r] = "Normal" -- the sole reader, SendSV, is guarded on
   rep_status[r] = "ViewChange", and both actions that reach that status (TimerSendSVC,
   ReceiveHigherSVC) reset rep_recv_dvc[r] first. This invariant is the regression check for that
   argument: re-run it before assuming the ValidDvc filter in SendSV is still inert, if the
   view-transition actions (especially ReceiveSV's reset discipline) ever change. *)
RecvDvcValidWhenViewChange ==
    \A r \in replicas :
        rep_status[r] = "ViewChange" => \A m \in rep_recv_dvc[r] : ValidDvc(r, m)

(* research §5.5: guarded by commit_number on BOTH replicas -- the unguarded version is
   wrong, because uncommitted log suffixes are allowed to diverge. Do not remove the guard. *)
NoLogDivergence ==
    \A op_number \in 1..Cardinality(Values) :
        ~ \E r1, r2 \in replicas :
            /\ op_number <= rep_commit_number[r1]
            /\ op_number <= rep_commit_number[r2]
            /\ rep_log[r1][op_number] # rep_log[r2][op_number]

(* ---- THROWAWAY finiteness probe (task 4's entire reason for existing) ----
   spec/tla/README.md, "A lesson for whoever plans the follow-up": the message bag is the only
   structure in this module that can grow without bound (its counts are Nat, not a bounded
   domain), so an action that re-enables itself and whose only effect is a bag increment makes
   the reachable state space INFINITE -- which no bound on any hardware can exhaust, and which
   presents as "this spec class is just intractable" if you do not check for it. Every other
   accumulator here is finite by construction: rep_recv_nacks saturates at `replicas`,
   rep_storage ranges over a 3-element domain and is fixed at Init.

   Threshold of 3 is from the README's own worked example. It is a tripwire, not a protocol
   property: nothing in VSR requires a bag count to stay under 3, it just happens to at this
   bound, so a breach means "something is growing monotonically" -- go look at which action.
   Delete this whole block when task 5 writes the real extension. *)
NoUnboundedGrowth == \A m \in DOMAIN messages : messages[m] < 3

AcknowledgedWritesExistOnMajority ==
    \A v \in Values :
        \/ ~aux_client_acked[v]
        \/ Cardinality({ r \in replicas :
                          \E i \in DOMAIN rep_log[r] : rep_log[r][i] = v })
             >= ((ReplicaCount - 1) \div 2) + 1
====
