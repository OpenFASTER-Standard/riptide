---- MODULE VSR_WideNoForfeit ----
(* VSR.tla at VSR_Wide's bound (Values = {v1, v2}, MaxOp = 2) with ForfeitLimit = 0 --
   see VSR_WideNoForfeit.cfg.

   Why this module exists. scripts/tlc VSR_Wide does not terminate (spec/tla/README.md
   quotes its real queue-growth numbers). Task 5's review observed that the counterexample
   trace which found the HasDvcQuorum defect uses no ForfeitViewChange action at all, so
   disabling that action removes a whole branching factor while keeping the defect class
   reachable -- the cheapest untried route to an EXHAUSTIVE result at the widened bound,
   which would be strictly stronger evidence than VSR_Wide's simulation-mode fallback.

   ForfeitLimit = 0 disables ForfeitViewChange outright (its guard is
   aux_forfeit_count < ForfeitLimit, and aux_forfeit_count starts at 0); 0 \in Nat, so
   VSR.tla's own ASSUME on the fault-budget constants still holds. No other constant, action
   or invariant differs from VSR_Wide's -- as there, everything is VSR.tla's by EXTENDS.

   What a clean run here would and would NOT say. It would be exhaustive evidence for the
   shipped invariants at two distinct values over the sub-protocol WITHOUT the forfeit
   escape. It says nothing about behaviours that forfeit; VSR_Wide's non-exhaustive
   simulation remains the only evidence covering those. Read it as a strictly-narrower
   bound checked strictly-harder, not as a replacement for VSR_Wide. *)
EXTENDS VSR
====
