---- MODULE VSR ----
(* VSR safety protocol, storage-fault-aware: normal-case operation, view change with DVC
   selection and STARTVIEW completion, and -- added by this plan's task 5 -- multi-step,
   interruptible view-change completion driven by nack quorums over a per-op tri-state
   storage abstraction, a forfeit escape, durable view/log_view across a simulated restart,
   and nack-quorum-proven log truncation.

   Message names, field lists, and quorum thresholds are verbatim from Liskov & Cowling,
   "Viewstamped Replication Revisited" (2012); "research §x.y" citations throughout refer to
   that paper's mechanics as catalogued in a research file external to this repo (not
   committed -- see spec/tla/README.md), research §1.3-§1.5, §2.4-§2.5. The storage-fault
   layer follows docs/superpowers/specs/2026-09-23-storage-fault-tolerant-recovery-design.md
   Decisions 4-6 and research §4.2, §4.7-§4.12.

   Deliberately excluded from this spec (see spec/tla/README.md): state-transfer, general
   crash modeling beyond the single durable-state restart action below, reconfiguration, the
   client-table, and COMMIT messages (pure liveness optimization). *)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS ReplicaCount, Values, StartViewOnTimerLimit,
          MaxOp,          \* size of the modelled WAL slot range, 1..MaxOp
          CorruptLimit,   \* max slots one restart may discover corrupt
          RestartLimit,   \* max crash/restart events in a behaviour
          ForfeitLimit    \* max view-change forfeits in a behaviour

replicas == 1..ReplicaCount
ops == 1..MaxOp

(* research §1.1: Primary is a pure function of the view number, never elected. *)
Primary(v) == 1 + ((v-1) % ReplicaCount)

(* Decision 5: uniform f+1 quorums everywhere. There is exactly one quorum size in this
   module -- no flexible/multi-sized quorums. *)
f == (ReplicaCount - 1) \div 2   \* 2f+1 = ReplicaCount
Quorum == f + 1

ValuesSymmetry == Permutations(Values)

(* ---- domain-boundedness assumptions ----
   Task 4's review, carried-forward requirement 6: bound growth by DOMAIN, not only by count.
   An op-number is only ever advanced by ReceiveClientRequest, which refuses a value already
   in the primary's log, so no replica's op-number can exceed Cardinality(Values). rep_storage
   is indexed by 1..MaxOp, so MaxOp must cover that range or the spec would index out of
   domain the moment Values is widened. Tie the two together explicitly rather than leaving it
   as a convention a later edit can silently break. *)
ASSUME MaxOp >= Cardinality(Values)
ASSUME ReplicaCount % 2 = 1
ASSUME CorruptLimit \in Nat /\ RestartLimit \in Nat /\ ForfeitLimit \in Nat

VARIABLES
    rep_log,               \* [replica -> Seq(Values)] -- the WAL's logical contents
    rep_op_number,         \* [replica -> Nat]
    rep_commit_number,     \* [replica -> Nat]
    rep_peer_op_number,    \* [replica -> [replica -> Nat]] -- primary's view of each peer's ack'd op-number
    messages,              \* bag: message record -> pending delivery count
    aux_client_acked,      \* [Values -> BOOLEAN], set true once the primary executes+would reply
    rep_status,            \* [replica -> {"Normal", "ViewChange"}]
    rep_view_number,       \* [replica -> Nat] -- DURABLE (superblock). Decision 4: persisted,
                           \* not reconstructed by VSR's textbook in-memory Recovery protocol.
    rep_last_normal_view,  \* [replica -> Nat] -- the paper's v', TigerBeetle's log_view.
                           \* research §1.2: NOT derivable from rep_view_number, an omission in
                           \* the paper's own Figure 2. Also DURABLE (superblock).
    rep_recv_svc,          \* [replica -> SUBSET replicas] -- STARTVIEWCHANGE senders for current view
    rep_recv_dvc,          \* [replica -> SUBSET [message]] -- DOVIEWCHANGE messages received.
                           \* Nack and present-entry evidence is PIGGYBACKED on these records
                           \* (Decision 4), so there is no separate nack accumulator -- see the
                           \* comment on SendDVC for why that is a deliberate safety property,
                           \* not just an economy.
    rep_sent_dvc,          \* [replica -> BOOLEAN] -- TRUE once this replica has sent its
                           \* DOVIEWCHANGE for the CURRENT view-change episode; cleared
                           \* whenever a new episode starts. Without it SendDVC re-enables
                           \* itself forever (nothing it reads changes when it fires), each
                           \* firing producing a distinct state that differs only in the
                           \* message bag's count -- an infinite reachable state space.
    aux_svc_count,         \* [replica -> Nat] -- bounds TimerSendSVC, research §6.3 point 4
    (* ---- storage-fault-aware recovery state ---- *)
    rep_storage,           \* [replica -> [1..MaxOp -> {"present","absent","corrupt"}]]
                           \* Decision 5's per-op tri-state abstraction. See "storage model"
                           \* below for the exact meaning of each value and, more importantly,
                           \* for which transitions between them are physically admissible.
    aux_restart_count,     \* Nat -- bounds CrashRestart
    aux_forfeit_count      \* Nat -- bounds ForfeitViewChange

vars == << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number, messages,
            aux_client_acked, rep_status, rep_view_number, rep_last_normal_view,
            rep_recv_svc, rep_recv_dvc, rep_sent_dvc, aux_svc_count,
            rep_storage, aux_restart_count, aux_forfeit_count >>

(* Convenience tuple so the seven actions that touch no recovery state can leave it untouched
   with one clause at the Next disjunction instead of three extra conjuncts each. The five
   that DO touch it (ReceiveClientRequest, ReceivePrepareMsg, SendSV, ReceiveSV, plus the two
   new recovery actions) state their own UNCHANGED explicitly. *)
recovery_vars == << rep_storage, aux_restart_count, aux_forfeit_count >>
aux_recovery_counters == << aux_restart_count, aux_forfeit_count >>

View(r) == rep_view_number[r]
IsNormalPrimary(r) == /\ rep_status[r] = "Normal" /\ Primary(View(r)) = r
IsNormalBackup(r)   == /\ rep_status[r] = "Normal" /\ Primary(View(r)) # r

(* ================================ storage model ================================
   rep_storage[r][o] is the durability status of replica r's WAL slot o.

     "present" -- the slot is readable and holds rep_log[r][o]. Only meaningful for
                  o <= Len(rep_log[r]).
     "corrupt" -- the slot's checksum does not verify. The replica CANNOT read the entry and
                  CANNOT prove it never held one there. Only reachable for
                  o <= Len(rep_log[r]).
     "absent"  -- the slot is readable and provably holds no entry for op o. The replica can
                  prove it never durably wrote op o here.

   THE LOAD-BEARING MODELLING DECISION, stated explicitly because every safety argument below
   rests on it: a slot that the replica has already durably written can fault only to
   "corrupt", never to "absent". This is not a convenience -- it is exactly the contract
   design Decision 6 buys with "every log entry gets a checksum in a redundant header,
   physically separate from the entry's own data, so a checksum mismatch cleanly means
   'corrupted,' never conflated with 'legitimately absent.'" A storage layer that could let a
   durably-acknowledged entry read back as a valid-but-empty slot would defeat ANY nack-based
   recovery protocol: two replicas could then jointly "prove" a committed op was never held.

   THAT IS MEASURED, NOT ARGUED. A deliberate mutation of CrashRestart -- one word, "corrupt"
   to "absent", so a restart may discover a durably-written slot provably empty -- violates
   NoCommittedOpProvablyAbsent at depth 6 in under a second (595 states generated, 328
   distinct, single-worker). TLC's trace is exactly the two-replica false proof above: op 1 is
   committed and client-acked, replica 2 legitimately nacks it (it never received the PREPARE,
   so its slot is honestly "absent"), and the mutated restart makes replica 1's WRITTEN slot
   read back "absent" too -- 2 of 3 replicas, a quorum, jointly "proving" a committed op was
   never held. Reproduce it (the derived module is deliberately not committed, so it cannot
   rot out of sync with this one) from spec/tla:
     sed -e 's/^---- MODULE VSR ----/---- MODULE VSR_AbsentFault ----/' \
         -e 's/|-> IF o \\in corrupted THEN "corrupt"/|-> IF o \\in corrupted THEN "absent"/' \
         VSR.tla > VSR_AbsentFault.tla
     grep -v 'INVARIANT StorageWellFormed' VSR.cfg > VSR_AbsentFault.cfg
     cd ../.. && scripts/tlc VSR_AbsentFault
   The DOUBLE backslash in '\\in' is load-bearing and is the one thing to get right if you retype
   this: the spec text being matched contains a literal backslash (TLA+'s '\in'), so a
   single-backslash sed pattern matches NOTHING. An earlier version of this comment had exactly
   that bug, and it fails in the worst possible way -- sed silently emits an unmutated copy, TLC
   reports the usual clean result, and the recipe appears to prove the OPPOSITE of what it is for.
   So check the OUTCOME, not just that the command ran: it must say
     Error: Invariant NoCommittedOpProvablyAbsent is violated.
   with 595 states generated / 328 distinct / depth 6 (single-worker). If it instead says "Model
   checking completed. No error has been found", the substitution missed -- confirm with
   'diff VSR.tla VSR_AbsentFault.tla', which must show the CrashRestart line changed, not just
   the module header.
   StorageWellFormed is dropped from the derived config on purpose: it is the direct restatement
   of the contract being mutated, so leaving it in would report the mutation itself rather than
   the SAFETY CONSEQUENCE of the mutation, which is the whole point of the exercise.

   Consequently "absent" holds precisely for o > Len(rep_log[r]) -- StorageWellFormed asserts
   that as a checkable invariant rather than leaving it as prose. *)
Holds(r, o)     == o <= Len(rep_log[r]) /\ rep_storage[r][o] = "present"
IsCorrupt(r, o) == o <= Len(rep_log[r]) /\ rep_storage[r][o] = "corrupt"

(* research §4.2, §4.8-§4.10: the "never nack a corrupt entry" rule. A replica may nack op o
   only when it can PROVE it never durably held it. A corrupt slot is precisely the case where
   it cannot. *)
CanNack(r, o) == rep_storage[r][o] = "absent"

(* Storage after the whole log is (re)written durably and verified -- what SendSV and
   ReceiveSV do when a replica adopts the new view's canonical log. This abstracts repair:
   STARTVIEW carries the complete log in this spec, so adopting it heals corruption. A real
   implementation repairs incrementally; disclosed in spec/tla/README.md. *)
FreshStorage(n) == [o \in ops |-> IF o <= n THEN "present" ELSE "absent"]

(* What r can actually READ, as a PARTIAL function defined exactly on its readable slots. Note
   this is deliberately not a readable *prefix*: a corrupt slot does not hide the slots after
   it, and a replica that can read op 2 but not op 1 is a real state this model must be able to
   express (CrashRestart can corrupt any subset). SendDVC ships exactly this -- a replica
   cannot send bytes it cannot read. *)
ReadableEntries(r) == [ o \in { o \in ops : Holds(r, o) } |-> rep_log[r][o] ]

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

(* ---- Init ----
   Every log is empty, so every slot is "absent" -- and note what that means for fault
   modelling: an initial-state storage fault is VACUOUS in this model. A replica with an empty
   log already provably holds nothing, so marking one of its slots faulted adds no evidence
   and no scenario. Faults only become meaningful once a replica has durably written an entry
   and then loses the ability to read it, which is why this spec injects faults at
   CrashRestart rather than at Init (task 4's probe did the opposite; see the report). *)
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
    /\ rep_storage = [r \in replicas |-> [o \in ops |-> "absent"]]
    /\ aux_restart_count = 0
    /\ aux_forfeit_count = 0

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
              /\ rep_storage' = [rep_storage EXCEPT ![r][n] = "present"]
              /\ Broadcast([type |-> "Prepare", view |-> View(r), n |-> n, v |-> v,
                            k |-> rep_commit_number[r], dest |-> r], r)
    /\ UNCHANGED << rep_commit_number, rep_peer_op_number, aux_client_acked, rep_status,
                    rep_view_number, rep_last_normal_view, rep_recv_svc, rep_recv_dvc,
                    rep_sent_dvc, aux_svc_count >>
    /\ UNCHANGED aux_recovery_counters

(* research §1.5 point 7: backups process PREPARE strictly in op-number order.
   research §1.4 step 7: a backup advances its commit-number to m.k whenever higher --
   safe unconditionally: a normal PREPARE's k is always the primary's commit-number from
   before the request carried by this same message was appended (m.k < m.n), and by the time
   a backup processes this message its own rep_op_number has just been set to m.n, so every
   entry up to m.k is already guaranteed present in its log.

   Appending and sending PREPAREOK are one step here, which is the model's statement that the
   entry is DURABLE before it is acknowledged. That is what licenses the storage model's rule
   that an acknowledged entry can only fault to "corrupt" -- see the storage model note. *)
ReceivePrepareMsg ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ IsNormalBackup(r)
        /\ ReceivableMsg(m, "Prepare", r)
        /\ m.view = View(r)
        /\ rep_op_number[r] + 1 = m.n
        /\ rep_log' = [rep_log EXCEPT ![r] = Append(@, m.v)]
        /\ rep_op_number' = [rep_op_number EXCEPT ![r] = m.n]
        /\ rep_storage' = [rep_storage EXCEPT ![r][m.n] = "present"]
        /\ rep_commit_number' = [rep_commit_number EXCEPT ![r] = IF m.k > @ THEN m.k ELSE @]
        /\ DiscardAndSend(m, [type |-> "PrepareOk", view |-> View(r), n |-> m.n, i |-> r,
                              dest |-> Primary(View(r))])
        /\ UNCHANGED << rep_peer_op_number, aux_client_acked, rep_status,
                        rep_view_number, rep_last_normal_view, rep_recv_svc, rep_recv_dvc,
                        rep_sent_dvc, aux_svc_count >>
        /\ UNCHANGED aux_recovery_counters

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
    LET acked_backups == Cardinality({ p \in replicas \ {r} :
                                        rep_peer_op_number[r][p] >= op_number })
    IN acked_backups >= f

(* Storage-fault-aware addition to the normal path: the primary must be able to READ the entry
   it is about to execute. Counting itself toward the f+1 while its own copy is unreadable
   would let a cluster commit with only f readable copies. *)
PrimaryExecuteOp ==
    \E r \in replicas :
        /\ IsNormalPrimary(r)
        /\ rep_commit_number[r] < rep_op_number[r]
        /\ LET next == rep_commit_number[r] + 1
           IN /\ Holds(r, next)
              /\ IsCommitted(r, next)
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
              /\ Broadcast([type |-> "StartViewChange", v |-> v, i |-> r, dest |-> r], r)
    /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                    aux_client_acked, rep_last_normal_view >>

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
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_last_normal_view, aux_svc_count >>

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

   Decision 4's piggyback, and the reason there is no separate nack accumulator variable in
   this module. The DOVIEWCHANGE carries the sender's complete storage evidence:

     entries -- a PARTIAL function, defined exactly on the ops this replica can actually read.
                Corrupt slots are simply not in its domain. This replaces the old unconditional
                `log |-> rep_log[r]` field: a replica cannot send bytes it cannot read.
     nacks   -- the ops it can PROVE it never durably held (research §4.2's rule; a corrupt
                slot is never nacked).
     n       -- its op-number, which it still knows from durable superblock state even when
                some slot bodies are unreadable.

   Because that evidence rides on the DVC record itself, every reader reaches it through
   rep_recv_dvc[r] and therefore through the SAME ValidDvc(r, m) view filter that already
   guards log selection. Task 4's draft kept a separate rep_recv_nacks accumulator, which
   reintroduced -- for nacks -- the exact stale-evidence-across-a-view-bump hazard
   spec/tla/README.md documents for rep_recv_dvc. Folding nacks into the DVC record removes
   that hazard structurally rather than defending against it with a second reset discipline
   and a second regression invariant: RecvDvcValidWhenViewChange now covers nack evidence too.

   The rep_sent_dvc one-shot flag is a modeling device, not protocol logic: a replica sends its
   DOVIEWCHANGE once per view-change episode. Without it this action's own effect leaves every
   one of its guards true, so it re-enables itself indefinitely and each firing yields a distinct
   state (one more copy of the same message in the bag) -- an infinite reachable state space that
   no exhaustive TLC run at any bound can terminate on. The flag mirrors how aux_svc_count already
   bounds TimerSendSVC (research §6.3 point 4), and is cleared by every action that begins a new
   view-change episode: TimerSendSVC, ReceiveHigherSVC, ForfeitViewChange, CrashRestart. *)
SendDVC ==
    \E r \in replicas :
        /\ rep_status[r] = "ViewChange"
        /\ ~rep_sent_dvc[r]
        /\ Cardinality(rep_recv_svc[r]) >= f
        /\ Send([type |-> "DoViewChange", v |-> View(r),
                  entries |-> ReadableEntries(r),
                  nacks |-> { o \in ops : CanNack(r, o) },
                  last_normal_view |-> rep_last_normal_view[r], n |-> rep_op_number[r],
                  k |-> rep_commit_number[r], i |-> r, dest |-> Primary(View(r))])
        /\ rep_sent_dvc' = [rep_sent_dvc EXCEPT ![r] = TRUE]
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_view_number, rep_status, rep_last_normal_view,
                        rep_recv_svc, rep_recv_dvc, aux_svc_count >>

ValidDvc(r, m) == m.v = View(r)

ReceiveDVC ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "DoViewChange", r)
        /\ ValidDvc(r, m)
        /\ rep_recv_dvc' = [rep_recv_dvc EXCEPT ![r] = @ \cup {m}]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_view_number, rep_status, rep_last_normal_view,
                        rep_recv_svc, rep_sent_dvc, aux_svc_count >>

(* ================= multi-step view-change completion (Decision 4) =================
   The would-be primary of the new view collects DVCs, then resolves every op in the candidate
   range before it may complete. This is the "multi-step, interruptible sequence rather than
   one extra field on DoViewChange" the design spec calls structural: with storage faults, the
   evidence needed to complete may simply not have arrived yet, and the coordinator must be
   able to WAIT (stay in ViewChange, keep accepting DVCs) or GIVE UP (ForfeitViewChange) --
   and can be interrupted at any point by a higher view. *)

ValidDvcs(r) == { m \in rep_recv_dvc[r] : ValidDvc(r, m) }

(* research §2.4 step 3 ("selects as the new log the one contained in the message with the
   largest v'; if several messages have the same v' it selects the one among them with the
   largest n"). Adapted from Vanlightly's own published, already-TLC-verified WinningDVC
   (research §5.7). Selection is on (last_normal_view, n) only -- deliberately NOT on the
   readable-entry domain, because op-number and log_view come from the durable superblock and
   remain trustworthy when entry bodies do not. *)
WinningDVC(r) ==
    CHOOSE m \in ValidDvcs(r) :
        ~ \E m1 \in ValidDvcs(r) :
            \/ m1.last_normal_view > m.last_normal_view
            \/ /\ m1.last_normal_view = m.last_normal_view
               /\ m1.n > m.n

(* research §5.7's explicit warning: this is a SEPARATE maximum, not derived from the winning
   DVC. *)
HighestCommitNumber(r) ==
    CHOOSE k \in { m.k : m \in ValidDvcs(r) } :
        ~ \E m \in ValidDvcs(r) : m.k > k

CanonicalView(r) == WinningDVC(r).last_normal_view

(* Replicas that share a log_view received their entries from the same primary, which assigns
   each op-number exactly once, so they cannot disagree about the value at an op. That makes
   any same-log_view DVC an admissible source for an entry the winner itself cannot read --
   this is how a corrupt slot on the would-be primary gets repaired from a peer rather than
   forcing a truncation. DvcEntriesAgreeWithinLogView checks the premise. Entries from a LOWER
   log_view are NOT admissible: those may be superseded values from an abandoned view. *)
EntrySources(r, o) ==
    { m \in ValidDvcs(r) : m.last_normal_view = CanonicalView(r) /\ o \in DOMAIN m.entries }

CanFill(r, o) == EntrySources(r, o) # {}
FillValue(r, o) == (CHOOSE m \in EntrySources(r, o) : TRUE).entries[o]

(* Uniform f+1 quorum (Decision 5). An op nacked by f+1 DISTINCT replicas cannot have been
   committed: committing op o requires f+1 replicas to have durably held it, any two f+1 sets
   of 2f+1 replicas intersect, and -- by the storage model's rule -- a replica that durably
   held an entry can never nack it (a lost write reads back corrupt, and a corrupt slot is
   never nacked). So an f+1 nack quorum PROVES the op was never committed, which is exactly
   what makes dropping it safe. *)
NackCount(r, o) == Cardinality({ m.i : m \in { d \in ValidDvcs(r) : o \in d.nacks } })
ProvenAbsent(r, o) == NackCount(r, o) >= Quorum

(* A completion at length L is admissible iff every op it KEEPS can actually be reconstructed,
   every op it DROPS was proven absent by a nack quorum, and it never drops below the highest
   commit-number any quorum member reported. Ops in neither category are CONTESTED and block
   completion -- "a quorum simply hasn't reported yet (must wait)", design spec Decision 4. *)
ValidCompletion(r, L) ==
    /\ L >= HighestCommitNumber(r)
    /\ \A o \in 1..L : CanFill(r, o)
    /\ \A o \in (L+1)..WinningDVC(r).n : ProvenAbsent(r, o)

CanComplete(r) == \E L \in 0..WinningDVC(r).n : ValidCompletion(r, L)

(* Prefer keeping: take the LONGEST admissible log. Truncation is a last resort taken only
   where a nack quorum forces it. *)
CompletionPoint(r) ==
    CHOOSE L \in 0..WinningDVC(r).n :
        /\ ValidCompletion(r, L)
        /\ \A L2 \in 0..WinningDVC(r).n : ValidCompletion(r, L2) => L2 <= L

(* research §2.5: "f+1 DOVIEWCHANGE from DIFFERENT replicas". The `{ m.i : ... }` projection is
   the whole point and is not decoration -- counting `Cardinality(ValidDvcs(r))` directly is a
   REAL safety defect, found by TLC at the widened bound (`scripts/tlc VSR_Wide`) and recorded in
   spec/tla/README.md. It is reachable precisely because THIS module makes one replica able to
   send two DOVIEWCHANGEs in the same view: CrashRestart clears rep_sent_dvc (correctly -- it is
   volatile in-memory state), so a replica that restarts mid-view-change re-sends, and its second
   DVC differs from its first (its entries field shrank when a slot faulted to corrupt), so the
   two are distinct records and both sit in the coordinator's set. Counted as messages they look
   like a quorum of two; they are one replica speaking twice.
   Everything the whole truncation argument rests on collapses without this projection: the
   classical VSR selection argument ("a committed op is durably held by f+1 replicas, any two
   f+1 sets intersect, so the winning DVC's own op-number covers it, so dropping past it is
   safe") is a statement about f+1 DISTINCT replicas and says nothing at all about f+1 messages.
   NackCount already projects the same way, for the same reason; this was the one site that did
   not. *)
HasDvcQuorum(r) ==
    /\ rep_status[r] = "ViewChange"
    /\ r = Primary(View(r))
    /\ Cardinality({ m.i : m \in ValidDvcs(r) }) >= Quorum

(* research §2.4 step 3 and §2.5 ("f+1 DOVIEWCHANGE from different replicas, including
   itself"), now gated additionally on CanComplete: the sequence may not complete while any
   contested op remains unresolved. The new log is reconstructed op-by-op from the canonical
   evidence rather than copied wholesale from the winner, because the winner may not be able
   to read all of its own entries. rep_storage is reset to FreshStorage(L): the new primary
   has just durably written and verified the canonical log. *)
SendSV ==
    \E r \in replicas :
        /\ HasDvcQuorum(r)
        /\ CanComplete(r)
        /\ LET L == CompletionPoint(r)
               new_log == [ o \in 1..L |-> FillValue(r, o) ]
               new_k == HighestCommitNumber(r)
           IN /\ rep_log' = [rep_log EXCEPT ![r] = new_log]
              /\ rep_op_number' = [rep_op_number EXCEPT ![r] = L]
              /\ rep_commit_number' = [rep_commit_number EXCEPT ![r] = new_k]
              /\ rep_storage' = [rep_storage EXCEPT ![r] = FreshStorage(L)]
              /\ rep_status' = [rep_status EXCEPT ![r] = "Normal"]
              /\ rep_last_normal_view' = [rep_last_normal_view EXCEPT ![r] = View(r)]
              /\ Broadcast([type |-> "StartView", v |-> View(r), log |-> new_log,
                            n |-> L, k |-> new_k, dest |-> r], r)
        /\ UNCHANGED << rep_peer_op_number, aux_client_acked, rep_view_number,
                        rep_recv_svc, rep_recv_dvc, rep_sent_dvc, aux_svc_count >>
        /\ UNCHANGED aux_recovery_counters

(* THE FORFEIT ESCAPE (Decision 4's "forfeit escape hatch"), and its exact trigger.

   Enabled precisely when this replica has everything the OLD, storage-fault-unaware protocol
   needed to complete -- it is the primary of its view, in ViewChange, holding a valid f+1 DVC
   quorum -- and STILL cannot complete, because at least one op in the candidate range is
   neither reconstructible from canonical evidence nor proven absent by a nack quorum. That is
   the one situation storage-fault-awareness newly creates and that no amount of waiting is
   guaranteed to resolve: the remaining f replicas may all be unreachable, or may all report
   the same corrupt slot, in which case the op is permanently contested for THIS view.

   Deliberately NOT enabled before the DVC quorum is reached. A coordinator short of a quorum
   must wait: more DVCs can only add evidence, never remove it, so forfeiting early would
   abandon an attempt that was still making progress. ("A quorum simply hasn't reported yet
   (must wait)", design spec Decision 4.)

   Effect: abandon this attempt and start a fresh view-change episode at view+1, so a
   different replica -- one whose own storage may be intact where this one's is not -- gets to
   coordinate. The replica stays in ViewChange; it does not fall back to Normal, because its
   durable view has already advanced. Bounded by ForfeitLimit for the same state-space reason
   aux_svc_count bounds TimerSendSVC; a real implementation bounds it with a timer.

   This also closes, for the storage-fault case only, the class of wedge recorded as
   simplification 3 in spec/tla/README.md (a replica already in ViewChange having no way to
   try a newer view). The general no-quorum-at-all timeout remains out of scope there. *)
ForfeitViewChange ==
    \E r \in replicas :
        /\ aux_forfeit_count < ForfeitLimit
        /\ HasDvcQuorum(r)
        /\ ~CanComplete(r)
        /\ LET v == View(r) + 1
           IN /\ rep_view_number' = [rep_view_number EXCEPT ![r] = v]
              /\ rep_recv_svc' = [rep_recv_svc EXCEPT ![r] = {}]
              /\ rep_recv_dvc' = [rep_recv_dvc EXCEPT ![r] = {}]
              /\ rep_sent_dvc' = [rep_sent_dvc EXCEPT ![r] = FALSE]
              /\ Broadcast([type |-> "StartViewChange", v |-> v, i |-> r, dest |-> r], r)
        /\ aux_forfeit_count' = aux_forfeit_count + 1
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_status, rep_last_normal_view, aux_svc_count,
                        rep_storage, aux_restart_count >>

(* research §2.4 step 5 (simplified for this spec's scope: skip re-sending PREPAREOK for
   uncommitted entries -- disclosed in spec/tla/README.md as a known simplification).

   Note the "IF m.k > @ THEN m.k ELSE @" guard on rep_commit_number -- research §5.7 Part 4's
   documented commit-number-monotonicity fix. Applying m.k unconditionally is a REAL,
   documented defect; do not simplify this back to unconditional assignment.

   Storage: adopting the canonical log means durably writing and verifying it, so rep_storage
   is reset to FreshStorage(m.n). A corrupt slot on this replica is repaired by this step. *)
ReceiveSV ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "StartView", r)
        /\ m.v >= View(r)
        /\ rep_log' = [rep_log EXCEPT ![r] = m.log]
        /\ rep_op_number' = [rep_op_number EXCEPT ![r] = m.n]
        /\ rep_storage' = [rep_storage EXCEPT ![r] = FreshStorage(m.n)]
        /\ rep_commit_number' = [rep_commit_number EXCEPT ![r] =
                                    IF m.k > @ THEN m.k ELSE @]  \* research §5.7 Part 4: monotonic only
        /\ rep_view_number' = [rep_view_number EXCEPT ![r] = m.v]
        /\ rep_status' = [rep_status EXCEPT ![r] = "Normal"]
        /\ rep_last_normal_view' = [rep_last_normal_view EXCEPT ![r] = m.v]
        /\ Discard(m)
        /\ UNCHANGED << rep_peer_op_number, aux_client_acked, rep_recv_svc, rep_recv_dvc,
                        rep_sent_dvc, aux_svc_count >>
        /\ UNCHANGED aux_recovery_counters

(* ================= crash / restart with durable view state (Decision 4) =================
   One action does two jobs, deliberately, and the reason is a state-space one worth naming:
   task 4 measured that an action enabled in EVERY reachable state does not add states, it
   MULTIPLIES the whole base state graph. Storage-fault discovery and crash-restart are both
   naturally that shape, and modelling them separately pays the multiplier twice. They are
   also the same event in reality: a replica discovers that a slot no longer verifies when it
   re-reads its WAL after a restart. So this is a single action.

   DURABLE (survives): rep_log, rep_op_number, rep_commit_number, rep_view_number,
   rep_last_normal_view. The last two are the point -- Decision 4 persists view/log_view
   rather than relying on VSR's textbook in-memory-only Recovery sub-protocol. Status is
   RECONSTRUCTED from them (view > log_view means this replica was mid-view-change and must
   resume there, not re-enter the old view as if nothing happened), which is exactly what the
   durable pair buys.

   VOLATILE (lost): rep_peer_op_number, rep_recv_svc, rep_recv_dvc, rep_sent_dvc -- all
   in-memory view-change bookkeeping. Note rep_recv_dvc is cleared, so this new view/status
   transition preserves the reset discipline RecvDvcValidWhenViewChange checks.

   STORAGE: the restart may discover up to CorruptLimit slots corrupt. It may NOT discover a
   written slot "absent" -- see the storage model note above, which also records the run that
   mutates this one word and watches NoCommittedOpProvablyAbsent fall at depth 6.

   ================ the enablement narrowing, and what actually makes it sound ================
   Enablement is narrowed to restarts that can MATTER: a restart that corrupts nothing AND
   happens while the replica is not mid-view-change (rep_view_number[r] = rep_last_normal_view[r])
   is not modelled.

   The saving is real but much smaller than the shape of the change suggests, and it is MEASURED,
   not estimated. Derive a guard-deleted module (replace the "\/ corrupted # {}" disjunct below
   with "\/ TRUE", rename the module, copy VSR.cfg unchanged) and run the shipped bound: 10473900
   states generated / 3926093 distinct, depth 45, 0 states left on queue, in 02min 07s -- against
   the narrowed spec's 9226786 / 3678650 / depth 45. That is 1.067x the distinct states: the guard
   buys about 6.7%, NOT the factor of two an earlier version of this comment claimed.

   This is a state-space REDUCTION, so the bar it has to clear is not "the excluded transitions
   look uninteresting" -- an earlier version of this comment said only that they are "a pure
   volatile-state reset with no bearing on any property here", which is too weak to license
   anything. The property that actually makes the reduction sound is:

     THE EXCLUDED TRANSITIONS ENABLE NO ACTION THAT WAS NOT ALREADY ENABLED, AND FALSIFY NO
     INVARIANT THAT WAS NOT ALREADY FALSE.

   An excluded transition changes exactly four variables (rep_status' = "Normal" = its own
   prior value, since status "ViewChange" is only ever established together with view > log_view,
   which this branch excludes by construction). Walking each of the four, against this module's
   own readers -- the walk is the argument, and it must be REDONE if any reader is added:

     - rep_peer_op_number -> 0. Read in exactly one place: IsCommitted, which is used only by
       PrimaryExecuteOp's guard, monotonically (it counts peers whose ack'd op-number is >=
       some op). Zeroing it can only shrink that count, so it only ever DISABLES
       PrimaryExecuteOp.
     - rep_recv_svc -> {}. Read in exactly one guard: SendDVC's Cardinality(rep_recv_svc[r]) >= f
       (f >= 1 by ASSUME ReplicaCount % 2 = 1 with ReplicaCount >= 3). Emptying it only ever
       DISABLES SendDVC. ReceiveMatchingSVC writes it (@ \cup {m.i}) but does not read it in a
       guard, so it cannot change ReceiveMatchingSVC's enablement -- and because that write is
       monotone in the set, the emptied branch stays pointwise <= the un-emptied one forever
       after, which is what makes the argument survive induction rather than hold one step.
     - rep_recv_dvc -> {}. Read only through ValidDvcs(r), whose only guard-level consumer is
       HasDvcQuorum (SendSV, ForfeitViewChange); emptying it makes that Cardinality 0, so both
       are DISABLED. ReceiveDVC writes it monotonically (@ \cup {m}) without reading it in a
       guard, same induction as above. The two invariants that read it --
       RecvDvcValidWhenViewChange and DvcEntriesAgreeWithinLogView -- are universally quantified
       over its members, so {} satisfies both VACUOUSLY: the excluded transition cannot create a
       violation either.
     - rep_sent_dvc -> FALSE. This is the only one that can ENABLE anything: SendDVC guards on
       ~rep_sent_dvc[r]. It is safe for a different reason -- SendDVC also guards on
       rep_status[r] = "ViewChange", and every excluded transition lands in "Normal" by
       construction (the excluded case is precisely ~(view > log_view), which is exactly what
       makes the status reconstruction produce "Normal"). So SendDVC is disabled in the excluded
       post-state regardless of the flag. Separately, every path INTO "ViewChange"
       (TimerSendSVC, ReceiveHigherSVC, ForfeitViewChange, CrashRestart) already sets this flag
       FALSE itself, so the reset is not what makes a later SendDVC possible in any case.

   This is an argument, not a machine-checked reduction, and that stays true in general: the
   SHIPPED run never sees the excluded transitions, so a future edit that adds a reader of any of
   those four variables -- especially a non-monotone one, or a guard that fires on a variable
   being EMPTY -- can invalidate this walk with no failing run to say so.

   At the CURRENT bound, though, there is one cheap corroboration worth naming, because it is a
   real machine check rather than more prose: the guard-deleted run measured just above -- in
   which TLC DOES explore every excluded transition -- passes all fifteen invariants. So at this
   bound the reduction is directly confirmed to exclude nothing that falsifies anything; what is
   unchecked is only whether that survives a future edit. Which makes the maintenance rule
   concrete: if you add such a reader, either redo this walk AND re-run the guard-deleted variant,
   or just delete the narrowing outright -- at ~6.7% it is easily affordable at the shipped
   bound. *)
CrashRestart ==
    \E r \in replicas : \E corrupted \in SUBSET (1..Len(rep_log[r])) :
        /\ aux_restart_count < RestartLimit
        /\ Cardinality(corrupted) <= CorruptLimit
        /\ \/ corrupted # {}
           \/ rep_view_number[r] > rep_last_normal_view[r]
        /\ rep_storage' = [rep_storage EXCEPT ![r] =
                              [o \in ops |-> IF o \in corrupted THEN "corrupt"
                                             ELSE rep_storage[r][o]]]
        /\ rep_status' = [rep_status EXCEPT ![r] =
                              IF rep_view_number[r] > rep_last_normal_view[r]
                              THEN "ViewChange" ELSE "Normal"]
        /\ rep_peer_op_number' = [rep_peer_op_number EXCEPT ![r] = [p \in replicas |-> 0]]
        /\ rep_recv_svc' = [rep_recv_svc EXCEPT ![r] = {}]
        /\ rep_recv_dvc' = [rep_recv_dvc EXCEPT ![r] = {}]
        /\ rep_sent_dvc' = [rep_sent_dvc EXCEPT ![r] = FALSE]
        /\ aux_restart_count' = aux_restart_count + 1
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, messages, aux_client_acked,
                        rep_view_number, rep_last_normal_view, aux_svc_count,
                        aux_forfeit_count >>

Next ==
    \/ (\E v \in Values : ReceiveClientRequest(v))
    \/ ReceivePrepareMsg
    \/ ReceivePrepareOkMsg /\ UNCHANGED recovery_vars
    \/ PrimaryExecuteOp /\ UNCHANGED recovery_vars
    \/ TimerSendSVC /\ UNCHANGED recovery_vars
    \/ ReceiveHigherSVC /\ UNCHANGED recovery_vars
    \/ ReceiveMatchingSVC /\ UNCHANGED recovery_vars
    \/ SendDVC /\ UNCHANGED recovery_vars
    \/ ReceiveDVC /\ UNCHANGED recovery_vars
    \/ SendSV
    \/ ReceiveSV
    \/ ForfeitViewChange
    \/ CrashRestart

Spec == Init /\ [][Next]_vars

(* ================================ safety invariants ================================ *)

TypeOK ==
    /\ \A r \in replicas : rep_op_number[r] \in Nat
    /\ \A r \in replicas : rep_commit_number[r] \in Nat
    /\ \A r \in replicas : rep_view_number[r] \in Nat
    /\ \A r \in replicas : rep_status[r] \in {"Normal", "ViewChange"}
    /\ \A r \in replicas : rep_sent_dvc[r] \in BOOLEAN
    /\ \A r \in replicas : \A o \in ops :
            rep_storage[r][o] \in {"present", "absent", "corrupt"}
    /\ aux_restart_count \in Nat /\ aux_forfeit_count \in Nat

CommitNumberNeverHigherThanOpNumber ==
    \A r \in replicas : rep_commit_number[r] <= rep_op_number[r]

(* The structural relationship NoLogDivergence implicitly relies on: it indexes
   rep_log[r][op_number] guarded only by op_number <= rep_commit_number[r], which is
   in-domain only because the log's length tracks the op-number exactly. Asserted
   explicitly rather than assumed. *)
LogLengthMatchesOpNumber ==
    \A r \in replicas : Len(rep_log[r]) = rep_op_number[r]

(* Carried-forward requirement 6 from task 4's review: bound the DOMAIN, not just counts.
   rep_storage is indexed by 1..MaxOp, so an op-number escaping that range would be an
   out-of-domain index, not merely a large number. ASSUME MaxOp >= Cardinality(Values) is the
   argument; this is the runtime check of it. *)
OpNumberWithinMaxOp ==
    \A r \in replicas : rep_op_number[r] <= MaxOp

(* The storage model's own well-formedness, asserted rather than assumed: "absent" means
   exactly "beyond my log", and a slot inside the log is present or corrupt but never absent.
   Every safety argument about nacks rests on this -- if an in-log slot could read back
   "absent", a replica could nack an entry it durably held. *)
StorageWellFormed ==
    \A r \in replicas : \A o \in ops :
        /\ (o > Len(rep_log[r]) => rep_storage[r][o] = "absent")
        /\ (o <= Len(rep_log[r]) => rep_storage[r][o] \in {"present", "corrupt"})

(* research §4.2's rule, as a checkable regression guard rather than prose. Structural at this
   scope (CanNack is defined in terms of "absent"), kept so an edit that widens CanNack has to
   confront it. *)
NeverNackCorruptOrHeld ==
    \A r \in replicas : \A o \in ops :
        (Holds(r, o) \/ IsCorrupt(r, o)) => ~CanNack(r, o)

(* README.md, "What the ValidDvc filter is actually doing here": rep_recv_dvc[r] can carry stale
   (no-longer-valid) entries forward across a view bump that ReceiveSV performs without clearing
   it, but only while rep_status[r] = "Normal" -- the readers (SendSV, ForfeitViewChange) are
   guarded on rep_status[r] = "ViewChange", and every action that reaches that status
   (TimerSendSVC, ReceiveHigherSVC, ForfeitViewChange, CrashRestart) resets rep_recv_dvc[r]
   first. This invariant is the regression check for that argument. It now also covers NACK
   evidence, which rides on these same records -- see SendDVC's comment. *)
RecvDvcValidWhenViewChange ==
    \A r \in replicas :
        rep_status[r] = "ViewChange" => \A m \in rep_recv_dvc[r] : ValidDvc(r, m)

(* The premise EntrySources relies on: two DVCs from the same log_view cannot disagree about
   the value at an op, because both got it from that view's single primary. If this ever
   failed, repairing a corrupt slot from a same-log_view peer would be unsound. *)
DvcEntriesAgreeWithinLogView ==
    \A r \in replicas :
        \A m1, m2 \in rep_recv_dvc[r] :
            m1.last_normal_view = m2.last_normal_view =>
                \A o \in (DOMAIN m1.entries) \cap (DOMAIN m2.entries) :
                    m1.entries[o] = m2.entries[o]

(* research §5.5: guarded by commit_number on BOTH replicas -- the unguarded version is
   wrong, because uncommitted log suffixes are allowed to diverge. Do not remove the guard. *)
NoLogDivergence ==
    \A op_number \in ops :
        ~ \E r1, r2 \in replicas :
            /\ op_number <= rep_commit_number[r1]
            /\ op_number <= rep_commit_number[r2]
            /\ rep_log[r1][op_number] # rep_log[r2][op_number]

AcknowledgedWritesExistOnMajority ==
    \A v \in Values :
        \/ ~aux_client_acked[v]
        \/ Cardinality({ r \in replicas :
                          \E i \in DOMAIN rep_log[r] : rep_log[r][i] = v })
             >= Quorum

(* ---- NEW, storage-fault-aware safety invariants (task 5) ---- *)

(* HEADLINE 1: the storage-fault analogue of NoLogDivergence. No committed op may ever be
   provably-absent on a quorum of replicas -- because a quorum of nacks is precisely the proof
   ProvenAbsent accepts as licence to DISCARD the op. If this can ever be false, a correct
   coordinator following the protocol exactly can truncate committed data. Note this is
   strictly stronger than "no coordinator actually did truncate it": it forbids the EVIDENCE
   for such a truncation from ever existing, anywhere, whether or not anyone is collecting it. *)
CommittedOp(o) == \E r \in replicas : o <= rep_commit_number[r]

NoCommittedOpProvablyAbsent ==
    \A o \in ops :
        CommittedOp(o) => Cardinality({ r \in replicas : CanNack(r, o) }) < Quorum

(* Storage-fault-aware companion to AcknowledgedWritesExistOnMajority: a majority holding an
   acknowledged write in their logs is not enough if none of them can READ it. At the checked
   bound (RestartLimit/CorruptLimit = 1) at most one copy can be corrupted, so a quorum's worth
   of copies always leaves at least one readable; widening either limit past f would make this
   legitimately false and is not a protocol defect. *)
AcknowledgedWritesReadableSomewhere ==
    \A v \in Values :
        \/ ~aux_client_acked[v]
        \/ \E r \in replicas : \E i \in DOMAIN rep_log[r] :
                rep_log[r][i] = v /\ Holds(r, i)

(* HEADLINE 2: "no premature StartView" -- the multi-step sequence cannot complete while a
   contested op remains unresolved. Stated on the artifact the completion emits, checked
   against ground truth, for a reason worth recording because the obvious alternative is
   wrong.

   REJECTED FORMULATION, and why. The natural first attempt re-derives SendSV's own
   CanComplete guard from the evidence the completing replica still holds:

     \A r : (r completed a view change into its own view, holding an f+1 DVC quorum)
              => \A o \in (rep_op_number[r]+1)..WinningDVC(r).n : ProvenAbsent(r, o)

   TLC violates that at depth 24 in 85s -- and the violation is a FALSE POSITIVE, not a
   protocol defect. SendSV leaves rep_recv_dvc[r] alone, so a DOVIEWCHANGE that arrives AFTER
   completion joins the set the invariant reads. A late DVC with a higher (log_view, n) than
   any the coordinator actually had retroactively changes WinningDVC(r), and with it the range
   of ops the invariant believes were discarded. The coordinator completed correctly on the
   f+1 evidence it held; the invariant re-scored it against evidence that did not exist yet.
   Recorded rather than quietly deleted: it looks exactly like a real bug, and the general
   lesson is that any invariant re-deriving an action's own guard from mutable state must be
   robust to that state moving afterwards -- or it is measuring history it cannot see.

   WHAT IS CHECKED INSTEAD. A StartView is exactly the step that makes a completion visible to
   everyone else, so: no StartView that its OWN ADDRESSEE would still accept may carry a log
   shorter than that addressee's commit-number. The two qualifications are both load-bearing
   and both were added after TLC rejected a version missing them:

     - m.dest. Messages in this bag are per-destination (Broadcast fans out to one record per
       recipient), so a StartView addressed to replica 3 can never be consumed by replica 1.
       Quantifying over all replicas instead of the addressee produced a violation at depth 15
       in 8s that was pure invariant error.
     - m.v >= rep_view_number[m.dest]. This is exactly ReceiveSV's own acceptance test, so a
       StartView from an abandoned view -- one its addressee has already moved past -- is
       excluded rather than counted against state it can no longer affect.

   What remains is precisely "a premature completion lost committed data", checked against
   real replica state rather than against the coordinator's own reconstructible evidence. *)
StartViewNeverDropsACommittedOp ==
    \A m \in DOMAIN messages :
        (messages[m] > 0 /\ m.type = "StartView") =>
            (m.v >= rep_view_number[m.dest] => rep_commit_number[m.dest] <= m.n)

(* The literal recovery-aware analogue of CommitNumberNeverHigherThanOpNumber, applied to the
   emitted completion rather than to a replica: a StartView must carry a complete log that
   covers its own commit-number. ValidCompletion's `L >= HighestCommitNumber(r)` clause is what
   makes this true; dropping that clause is the single easiest way to write a premature
   completion, and this is the tripwire for it. *)
StartViewCoversItsOwnCommitPoint ==
    \A m \in DOMAIN messages :
        (messages[m] > 0 /\ m.type = "StartView") =>
            /\ Len(m.log) = m.n
            /\ m.k <= m.n

(* Finiteness tripwire, kept in the shipped config rather than deleted with task 4's draft.
   Nothing in VSR requires a bag count to stay below this -- it is a regression guard against
   reintroducing a self-enabling send action (the SendDVC/SendNack defect class), which is the
   single most expensive mistake to misdiagnose in this spec. A breach means "some action is
   growing the bag monotonically", not "the protocol is unsafe". *)
NoUnboundedGrowth == \A m \in DOMAIN messages : messages[m] < 4
====
