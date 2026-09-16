# Riptide v2

A from-scratch, general-purpose, ultra-rigorous critical-infrastructure data/event platform.

This branch (`v2-from-scratch`) starts empty on purpose — no backwards compatibility with v1
(the Solid/LDP/RDF/StreamLD-based system on `main`), no legacy baggage. v1's full history stays
untouched on `main` and every other existing branch.

## Where the design comes from

Every task in `.taskmaster/tasks/tasks.json` is grounded in a specific research finding, not
invented on the spot — real-world precedent (TigerBeetle, FoundationDB, WebAssembly, Kubernetes,
Ethereum's multi-client model, seL4, Knight-Leveson's N-version programming study and its 2026 AI
replication, and more), cross-checked against independent reasoning where the synthesis was novel
rather than established practice. Each task's `details` field cites what it's grounded in.

## Working the plan

```bash
npx -p task-master-ai task-master list          # see all tasks
npx -p task-master-ai task-master next           # what to work on next
npx -p task-master-ai task-master show <id>      # full detail on one task
npx -p task-master-ai task-master set-status --id=<id> --status=in-progress
```

Task 1 first: the process discipline it establishes (small aligned team, no spec ever ships
without real running code in the same cycle) is the single variable that separated every
historical success from every historical failure researched for a system this ambitious.

Tasks are sequential by design (see each task's `dependencies`) — this is deliberate. The
single most important sequencing lesson from the research: build one real, demanding use case
end-to-end (Task 6) before generalizing further, the same way WebAssembly proved itself on real
C/C++ workloads before WASI opened it to genuinely diverse use, and Kubernetes' CRD mechanism
proved itself on real Prometheus/cert-manager/Istio deployments before being trusted as settled.

## Documentation

Layer 0's `.mli` files are the authoritative specification (see `CLAUDE.md`'s "no spec without
running code" rule) — generate readable docs from them with:

    dune build @doc

Output lands in `_build/default/_doc/_html/riptide/`.

## Conformance

`spec/golden/vectors.txt` is a golden-vector conformance artifact: fixed canonical encodings and
content hashes for a representative set of values and one envelope, regenerated via
`dune exec spec/golden/generate.exe` and checked for regression in `test/test_golden.ml`. A future
second, independent implementation of Layer 0 should be checkable against this same file.

## Deterministic simulation substrate (proof-of-concept)

`lib/sim/` (`riptide_sim` library) is a proof-of-concept proving the substrate a real
deterministic-simulation-testing (DST) harness will be built on, per
`docs/superpowers/specs/2026-09-16-distributed-consensus-design.md`'s Decision 2. It proves,
against this project's real installed OCaml 5 / Eio toolchain rather than by assumption:

- `Prng`: every random decision in this library flows through one explicitly-seeded source.
- `Network`: an in-memory, peer-addressed, fault-injecting (delay/drop/duplicate/corrupt) message
  network, built directly on `Eio.Stream` and `Eio_mock.Clock` (`Eio_mock.Net` was evaluated and
  rejected — it is a scripted single-endpoint mock, not shaped for an N-peer simulated topology).
- `Workload`: a toy multi-fiber cluster with a randomly-generated (not fixed-script) workload,
  proving that identical seeds reproduce byte-for-byte identical traces even with fault injection
  enabled. (Note: this toy cluster resolves the network fully before any peer fiber runs, so it
  doesn't itself exercise genuine concurrent fiber/network interleaving. That composite property —
  fibers genuinely blocking on `Network.receive`, interleaved with *active* fault injection
  (nonzero duplicate/corrupt/delay), still reproducing byte-identically from the same seed — is
  proven by `test/test_sim_network.ml`'s "interleaving + active fault injection + determinism,
  combined" test.)

**What this does NOT yet build:** the real VSR-derived consensus protocol, atomic multi-entity
commit, or a production (real-socket) network implementation — those are separate, later
task-master subtasks (3.1, 3.3, 3.5) that will be built against this validated substrate, per the
spec's own required sequencing (this proof-of-concept exists specifically to happen *before* that
work is architected).
