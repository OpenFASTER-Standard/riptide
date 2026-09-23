---- MODULE VSR_Probe ----
(* Vacuity / reachability probes for VSR.tla's storage-fault-aware recovery, run separately
   from the shipped invariant set and NEVER shipped in VSR.cfg.

   Each predicate here is written to be FALSE on some reachable state. A TLC "Invariant ... is
   violated" result is therefore the SUCCESS case: it proves the corresponding piece of the
   recovery machinery is genuinely exercised at the checked bound, rather than a safety
   invariant passing because the state that would test it is unreachable. This is the same
   vacuity discipline spec/tla/README.md already applies to NoLogDivergence at Values = {v1}.

   Run one at a time: put exactly one INVARIANT line in VSR_Probe.cfg. TLC stops at the first
   violation, so probing several at once only tells you about whichever is found first. *)
EXTENDS VSR

(* P1: is a storage fault ever actually discovered? If this holds, every fault-dependent
   invariant below it is vacuous. *)
NoCorruptionEver == \A r \in replicas : \A o \in ops : ~IsCorrupt(r, o)

(* P2: does a crash/restart ever happen while the replica is mid-view-change -- the case that
   makes durable view/log_view load-bearing (status is reconstructed as "ViewChange" from
   view > log_view rather than silently reverting to "Normal")? *)
NoRestartEver == aux_restart_count = 0

(* P3: THE multi-step probe. Is a would-be primary ever stuck holding a full f+1 DVC quorum --
   everything the storage-fault-UNAWARE protocol needed to complete atomically -- and still
   unable to complete because an op is contested? If this holds, view-change completion is
   still effectively atomic at this bound and the whole multi-step design is untested. *)
NoContestedCompletion ==
    \A r \in replicas : ~(HasDvcQuorum(r) /\ ~CanComplete(r))

(* P4: does the forfeit escape ever fire? *)
NoForfeitEver == aux_forfeit_count = 0

(* P5: does a nack QUORUM (not just a single nack) ever form for an op inside the canonical
   winner's range -- i.e. is the "safe to drop" branch of ValidCompletion ever taken on real
   evidence, rather than completion always succeeding because nothing needed dropping? *)
NoNackQuorumInRange ==
    \A r \in replicas :
        ~ \E o \in ops :
            /\ HasDvcQuorum(r)
            /\ o <= WinningDVC(r).n
            /\ ProvenAbsent(r, o)

(* P6: is NoCommittedOpProvablyAbsent's antecedent reachable at all? It asserts that fewer
   than f+1 replicas can nack a committed op. If no committed op is ever nackable by even ONE
   replica, the invariant is guarding a situation that never arises. *)
NoNackOfACommittedOp ==
    \A o \in ops : ~(CommittedOp(o) /\ \E r \in replicas : CanNack(r, o))

(* P7: does a completed view change ever actually SHORTEN a log -- is truncation real here, or
   does completion always keep everything? Checked on the emitted artifact against a replica
   that would accept it. *)
NoStartViewShortensALog ==
    \A m \in DOMAIN messages :
        (messages[m] > 0 /\ m.type = "StartView") =>
            (m.v >= rep_view_number[m.dest] => rep_op_number[m.dest] <= m.n)

(* P8 and P9 are a WEAKER KIND OF PROBE than P1-P7, and are labelled as such in
   spec/tla/README.md rather than quietly listed alongside them. P1-P7 each show that a
   mechanism the shipped invariants depend on is genuinely exercised. P8 and P9 instead show
   only that the SITUATION two specific invariants describe actually arises at this bound --
   which is necessary for those invariants to be worth anything, but is NOT the same as
   showing they could fail. Both invariants remain, by argument, unfalsifiable at the shipped
   fault budget; see README.md's structural-guards list. Reachability of an antecedent is not
   falsifiability of an invariant, and conflating the two is exactly the overstatement these
   probes exist to stop this file from making. *)

(* P8: AcknowledgedWritesReadableSomewhere asserts that a client-acknowledged write is readable
   on SOME replica. At CorruptLimit = RestartLimit = 1 that cannot fail (at most one copy is
   ever unreadable, and an acknowledged write exists on a quorum). So the falsifiable question
   is the weaker one: does a copy of an ACKNOWLEDGED write ever actually become unreadable at
   all? If not, the invariant is not merely unfalsifiable but describes a situation that never
   arises, and CorruptLimit > 1 would be measuring nothing new either. *)
NoAckedValueEverCorrupt ==
    \A v \in Values : \A r \in replicas : \A i \in DOMAIN rep_log[r] :
        ~(aux_client_acked[v] /\ rep_log[r][i] = v /\ IsCorrupt(r, i))

(* P9: StartViewCoversItsOwnCommitPoint's second clause (m.k <= m.n) is trivially true of any
   StartView carrying commit-number 0. Is a completion ever emitted with a NON-ZERO commit
   point -- i.e. is that clause ever checked against a completion that had a real commit point
   to cover? (Its first clause, Len(m.log) = m.n, is well-formedness and has no comparable
   "interesting antecedent" to probe for.) *)
NoStartViewWithCommitPoint ==
    \A m \in DOMAIN messages :
        ~(messages[m] > 0 /\ m.type = "StartView" /\ m.k > 0)
====
