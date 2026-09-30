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
npx -p task-master-ai task-master set-status --id=3.4 --status=done  # subtasks, never parents
```

Only ever set a *subtask's* status directly — a parent task's status is always derived from its
subtasks, never asserted by hand (see `CLAUDE.md`'s "Task status is derived, never asserted").
Every subtask moving to `done` needs an `evidence` object in `tasks.json` citing a real,
git-verifiable commit SHA for the work, added by hand in the same change (`task-master`'s CLI has
no concept of this field). `scripts/validate-tasks` checks both — parent/child status agreement
and evidence resolvability — and runs in CI on every change to `tasks.json`.

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
- `Workload`: a toy multi-fiber cluster with a randomly-generated (not fixed-script) workload
  (sender, receiver, and payload shape/content all drawn from the seeded PRNG), proving that
  identical seeds
  reproduce byte-for-byte identical traces even with fault injection enabled - including genuine
  byte-level corruption (`Workload.random_byte_flip` mutates exactly one byte of a payload, per
  the design spec's explicit "not just whole-message" requirement; `Network`'s corruption
  interface is a caller-supplied `'msg -> 'msg` function, so byte-level corruption is a choice of
  function, not a `Network`-level feature). (Note: this toy cluster resolves the network fully
  before any peer fiber runs, so it
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

## WASM toolchain setup (wasmtime) — required patch after `opam install wasmtime`

`lib/module/loader.ml` (Task 5, subtask 3) runs real, compiled WASM via the `wasmtime` opam
package (`v0.0.3`). As pinned by that package's own opam file, it links against
`libwasmtime.0.22.0`, whose vendored `raw-cpuid` crate panics
(`assertion failed: res.eax == 0`) the instant ANY compiled WASM function is actually called, on
some modern CPUs (confirmed on this project's own dev box, an Intel Xeon Platinum 8581C exposing
AMX/AVX-512-FP16 CPUID leaves that plainly didn't exist when that crate version was written circa
2020) — a hard environment/library-version bug, independent of anything in this repo's own code.

**After `opam install wasmtime`, before building anything that uses it, apply
`patches/wasmtime-0.0.3-cpuid-and-gc-safety.patch`** and rebuild the package in place:

```bash
# 1. Swap the pinned libwasmtime (0.22.0) for wasmtime's official v49.0.1 C-API release, whose
#    updated raw-cpuid no longer trips on modern CPUID leaves. (The wasmtime opam wrapper's own
#    API surface it binds — non-"wasmtime_"-prefixed classic wasm_c_api — is unaffected by this
#    version jump; see the patch's own top comments for exactly what did change and how it's
#    handled.)
LIBDIR="$OPAM_SWITCH_PREFIX/lib/libwasmtime"
curl -sL https://github.com/bytecodealliance/wasmtime/releases/download/v49.0.1/wasmtime-v49.0.1-x86_64-linux-c-api.tar.xz \
  -o /tmp/wasmtime-v49.tar.xz
tar xf /tmp/wasmtime-v49.tar.xz -C /tmp
rm -rf "$LIBDIR/include" "$LIBDIR/lib"
cp -r /tmp/wasmtime-v49.0.1-x86_64-linux-c-api/include "$LIBDIR/include"
cp -r /tmp/wasmtime-v49.0.1-x86_64-linux-c-api/lib "$LIBDIR/lib"

# 2. Apply the patch to opam's own extracted source checkout of the wasmtime OCaml package, then
#    rebuild and reinstall it into the switch.
SRC="$OPAM_SWITCH_PREFIX/.opam-switch/sources/wasmtime.0.0.3"
patch -p1 -d "$SRC" < patches/wasmtime-0.0.3-cpuid-and-gc-safety.patch
(cd "$SRC" && dune build @install -p wasmtime -j 4 && dune install wasmtime --prefix "$OPAM_SWITCH_PREFIX")
```

The patch (against pristine `wasmtime.0.0.3` source, `LaurentMazare/ocaml-wasmtime@v0.0.3`) does
three things, each explained in detail in its own top-of-file comment in the patched sources:
adapts `bindings.ml`/`wrappers.ml`/`wrappers.mli` to v49's renamed/removed convenience functions
and vec-based calling convention (dropping WASI/`Linker`/`extern_ref` support, unused by this
repo's own hand-rolled ABI); and fixes two real, pre-existing GC-liveness bugs in the upstream
binding (a host-import function not kept reachable for its instance's full lifetime, and a
`Foreign.funptr`→`static_funptr` coercion only protecting the coerced value instead of the
original closure ctypes-foreign's own registry keys off) that surfaced once real WASM execution
was possible against this box's CPU for the first time. Verified live: the patch applies cleanly
(`patch -p1`) to a byte-identical fresh checkout of the pristine source and the result builds; see
`.superpowers/sdd/2026-09-30-layer0-layer2-boundary/task-3-report.md` for the full diagnostic
trail (every standalone repro, in order, with exact error text) behind each of the three changes.

## cosign (admission-gate signing) toolchain setup

`lib/module/admission.ml` (Task 5, subtask 4) shells out to a real, locally-installed
[`cosign`](https://github.com/sigstore/cosign) binary to verify a WASM artifact's signature
before it is ever admitted — never a placeholder/stubbed check. `cosign` is not baked into this
box's image and must be installed once, durably, the same way this project's own OCaml toolchain
already is (see this repo's own `CLAUDE.md`): everything outside `/work` is on the container's
ephemeral overlay and can vanish between sessions with no restart notice.

Install the Linux amd64 release binary directly from GitHub releases into
`/work/toolchain/bin` (the same durable directory the OCaml toolchain's own `opam` binary
already lives in):

```bash
mkdir -p /work/toolchain/bin
curl -fsSL -o /work/toolchain/bin/cosign \
  https://github.com/sigstore/cosign/releases/download/v3.1.3/cosign-linux-amd64
chmod +x /work/toolchain/bin/cosign
```

(`v3.1.3` was the latest release at install time — check
`https://github.com/sigstore/cosign/releases/latest` for a newer one before installing.)

**Two real, live-confirmed `cosign` v3.1.3 flag-surface changes worth knowing before writing
code or tests against it** — this task's own originating brief was written against an older
release, and its pseudocode (`cosign sign-blob --output-signature <path>.sig`,
`cosign verify-blob --signature <path>.sig`) no longer runs at all against v3.1.3: both flags
were fully removed in favor of a single `--bundle <file>` JSON bundle (signature plus, for the
keyless path, certificate/transparency-log material). `admission.ml`'s own top comment has the
full diagnostic trail; the short version:

1. **By default, `sign-blob`/`verify-blob` reach out to the real, public Sigstore Rekor
   transparency log over the network** — confirmed live (a `tlogEntries` block with a genuine
   `rekor.sigstore.dev` log index/checkpoint appeared in a bundle produced with no extra flags).
   For local-keypair signing with no live network dependency (this project's own test suite,
   and this task's own disclosed open-question resolution), pass **both**
   `--tlog-upload=false --use-signing-config=false` to `sign-blob` (confirmed live:
   `--tlog-upload=false` alone is rejected — "not supported with --signing-config or
   --use-signing-config" — it must be paired with `--use-signing-config=false`), and both
   `--insecure-ignore-tlog=true --insecure-ignore-sct=true` to `verify-blob` (cosign's own
   naming — this only skips the *additional* Rekor-inclusion/SCT check, never the actual
   cryptographic signature verification itself, which this project's admission gate never
   skips).
2. **`generate-key-pair`/`sign-blob` prompt interactively for a private-key password** unless
   `COSIGN_PASSWORD` is set in the environment (confirmed live: omitting it under a
   non-interactive runner hangs on "Enter password for private key:", then fails with an ioctl
   error). Only matters for signing (test fixtures / a real deployment's own signing pipeline) —
   `Admission.verify` itself only ever reads a *public* key, which `cosign` never
   password-prompts for.

Verify the install actually works, end to end, before relying on it — a real
`generate-key-pair` → `sign-blob` → `verify-blob` → tamper → `verify-blob`-fails round trip in a
scratch directory:

```bash
export PATH=/work/toolchain/bin:$PATH COSIGN_PASSWORD=""
cosign version
dir=$(mktemp -d) && cd "$dir"
echo -n "fake wasm bytes" > module.wasm
cosign generate-key-pair
cosign sign-blob --key cosign.key --bundle module.wasm.bundle \
  --tlog-upload=false --use-signing-config=false --yes module.wasm
cosign verify-blob --key cosign.pub --bundle module.wasm.bundle \
  --insecure-ignore-tlog=true --insecure-ignore-sct=true module.wasm   # Verified OK
printf TAMPERED >> module.wasm
cosign verify-blob --key cosign.pub --bundle module.wasm.bundle \
  --insecure-ignore-tlog=true --insecure-ignore-sct=true module.wasm   # Error, nonzero exit
```
