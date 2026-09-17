---- MODULE VSR ----
(* Core VSR safety protocol: normal-case operation (this module fragment) plus view change
   (Task 4 of this plan adds to the same Next disjunction below). Message names, field lists,
   and quorum thresholds are verbatim from Liskov & Cowling, "Viewstamped Replication
   Revisited" (2012), per this plan's research file, research §1.3-§1.5.

   Deliberately excluded from this spec (see this plan's Global Constraints and
   research §7.3): state-transfer, storage-fault-aware recovery, crash modeling,
   reconfiguration, the client-table, and COMMIT messages (pure liveness optimization). *)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS ReplicaCount, Values

replicas == 1..ReplicaCount

(* research §1.1: Primary is a pure function of the view number, never elected. *)
Primary(v) == 1 + ((v-1) % ReplicaCount)

VARIABLES
    rep_log,             \* [replica -> Seq(Values)]
    rep_op_number,       \* [replica -> Nat]
    rep_commit_number,   \* [replica -> Nat]
    rep_peer_op_number,  \* [replica -> [replica -> Nat]] -- primary's view of each peer's ack'd op-number
    messages,            \* bag: message record -> pending delivery count
    aux_client_acked     \* [Values -> BOOLEAN], set true once the primary executes+would reply

vars == << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number, messages, aux_client_acked >>

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

(* ---- Init ---- *)
Init ==
    /\ rep_log = [r \in replicas |-> <<>>]
    /\ rep_op_number = [r \in replicas |-> 0]
    /\ rep_commit_number = [r \in replicas |-> 0]
    /\ rep_peer_op_number = [r \in replicas |-> [p \in replicas |-> 0]]
    /\ messages = <<>>
    /\ aux_client_acked = [v \in Values |-> FALSE]

(* ---- normal-case actions, research §1.4 steps 1-7 (fixed single primary = Primary(0)
   for this fragment; Task 4 generalizes to Primary(View(r))) ---- *)

ReceiveClientRequest(v) ==
    LET p == Primary(0) IN
    /\ v \notin { rep_log[p][i] : i \in DOMAIN rep_log[p] }
    /\ LET n == rep_op_number[p] + 1
       IN /\ rep_log' = [rep_log EXCEPT ![p] = Append(@, v)]
          /\ rep_op_number' = [rep_op_number EXCEPT ![p] = n]
          /\ Broadcast([type |-> "Prepare", n |-> n, v |-> v,
                        k |-> rep_commit_number[p], dest |-> p], p)
    /\ UNCHANGED << rep_commit_number, rep_peer_op_number, aux_client_acked >>

(* research §1.5 point 7: backups process PREPARE strictly in op-number order. *)
ReceivePrepareMsg ==
    LET p == Primary(0) IN
    \E r \in replicas \ {p}, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "Prepare", r)
        /\ rep_op_number[r] + 1 = m.n
        /\ rep_log' = [rep_log EXCEPT ![r] = Append(@, m.v)]
        /\ rep_op_number' = [rep_op_number EXCEPT ![r] = m.n]
        /\ DiscardAndSend(m, [type |-> "PrepareOk", n |-> m.n, i |-> r, dest |-> p])
        /\ UNCHANGED << rep_commit_number, rep_peer_op_number, aux_client_acked >>

(* research §1.5 point 2: PREPAREOK is cumulative, so peer state is a single high-water mark. *)
ReceivePrepareOkMsg ==
    LET p == Primary(0) IN
    \E m \in DOMAIN messages :
        /\ ReceivableMsg(m, "PrepareOk", p)
        /\ rep_peer_op_number' = [rep_peer_op_number EXCEPT ![p][m.i] =
                                    IF m.n > @ THEN m.n ELSE @]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, aux_client_acked >>

(* research §1.5 point 1: f PREPAREOKs from OTHER replicas = f+1 counting the primary itself. *)
IsCommitted(op_number) ==
    LET p == Primary(0)
        f == (ReplicaCount - 1) \div 2   \* 2f+1 = ReplicaCount
        acked_backups == Cardinality({ r \in replicas \ {p} :
                                        rep_peer_op_number[p][r] >= op_number })
    IN acked_backups >= f

PrimaryExecuteOp ==
    LET p == Primary(0) IN
    /\ rep_commit_number[p] < rep_op_number[p]
    /\ LET next == rep_commit_number[p] + 1
       IN /\ IsCommitted(next)
          /\ rep_commit_number' = [rep_commit_number EXCEPT ![p] = next]
          /\ aux_client_acked' = [aux_client_acked EXCEPT ![rep_log[p][next]] = TRUE]
    /\ UNCHANGED << rep_log, rep_op_number, rep_peer_op_number, messages >>

Next ==
    \/ \E v \in Values : ReceiveClientRequest(v)
    \/ ReceivePrepareMsg
    \/ ReceivePrepareOkMsg
    \/ PrimaryExecuteOp

Spec == Init /\ [][Next]_vars

(* ---- safety invariants ---- *)
TypeOK ==
    /\ \A r \in replicas : rep_op_number[r] \in Nat
    /\ \A r \in replicas : rep_commit_number[r] \in Nat

CommitNumberNeverHigherThanOpNumber ==
    \A r \in replicas : rep_commit_number[r] <= rep_op_number[r]

(* research §5.5: guarded by commit_number on BOTH replicas -- the unguarded version is
   wrong, because uncommitted log suffixes are allowed to diverge. Do not remove the guard. *)
NoLogDivergence ==
    \A op_number \in 1..Cardinality(Values) :
        ~ \E r1, r2 \in replicas :
            /\ op_number <= rep_commit_number[r1]
            /\ op_number <= rep_commit_number[r2]
            /\ rep_log[r1][op_number] # rep_log[r2][op_number]

AcknowledgedWritesExistOnMajority ==
    \A v \in Values :
        \/ ~aux_client_acked[v]
        \/ Cardinality({ r \in replicas :
                          \E i \in DOMAIN rep_log[r] : rep_log[r][i] = v })
             >= ((ReplicaCount - 1) \div 2) + 1
====
