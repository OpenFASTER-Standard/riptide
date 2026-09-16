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
