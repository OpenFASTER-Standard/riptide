---- MODULE Smoke ----
(* Proves the TLA+ toolchain (tla2tools.jar, durably installed under /work/toolchain/tla/,
   see cloud-admin-box's own CLAUDE.md) works end-to-end from this repo's actual directory
   structure, before any real protocol module depends on it. *)
EXTENDS Naturals

VARIABLE n

Init == n = 0
Next == n < 9 /\ n' = n + 1
Spec == Init /\ [][Next]_n

TypeOK == n \in Nat
====
