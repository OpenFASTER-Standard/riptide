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
====
