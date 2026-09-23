---- MODULE VSR_Wide ----
(* VSR.tla at a WIDER bound: Values = {v1, v2}, MaxOp = 2 (see VSR_Wide.cfg).

   Why this module exists at all, rather than a second .cfg for VSR: spec/tla/README.md quotes
   `scripts/tlc VSR`'s exhaustive result verbatim as this branch's reproducible evidence, and
   `scripts/tlc <module>` resolves exactly one config per module. A separate module keeps the
   shipped bound's numbers literally reproducible by anyone who clones the branch, the same
   reasoning task 4 used for VSR_RecoveryDraft.

   What it is FOR. spec/tla/README.md discloses that NoLogDivergence is structurally
   unfalsifiable at Values = {v1} -- with one possible value anywhere in the system, two
   committed entries can never disagree. Task 5's storage-fault-aware extension adds a
   nack-quorum-driven TRUNCATION path, which is precisely a new way for two replicas' logs to
   end up disagreeing, so leaving NoLogDivergence vacuous at the shipped bound would leave the
   single invariant most relevant to the new mechanism untested. This module is the measured
   answer to "is widening affordable?", which task 5's binding requirement 4 asks be decided
   explicitly rather than assumed.

   Values and MaxOp are widened IN LOCKSTEP, which is what VSR.tla's own
   `ASSUME MaxOp >= Cardinality(Values)` enforces: op-numbers are bounded by the number of
   distinct values (ReceiveClientRequest refuses a value already in the primary's log), and
   rep_storage is indexed by 1..MaxOp, so widening Values alone would silently under-cover the
   fault model -- and widening it past MaxOp would index out of domain.

   Everything else -- every action, every invariant -- is VSR.tla's, unmodified, by EXTENDS.
   There is deliberately no new operator here: a divergence between this module and VSR.tla
   would make its result evidence about something other than the shipped spec. *)
EXTENDS VSR
====
