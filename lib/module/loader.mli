(** WASM module loading, host-ABI wiring, and SFI isolation (Task 5, subtask 3 / Decision 5).

    One fresh {!t} per {!instantiate} call, never reused across invocations — separate linear
    memory, no stale state carried between invocations, by construction (Decision 5). The
    guest-facing ABI (Decision 3) is a small, fixed, hand-rolled calling convention documented at
    the top of [loader.ml], not the WebAssembly Component Model (no OCaml runtime supports it
    yet).

    Consumed by Task 4 (protocol enforcement wraps {!invoke}) and Task 6 (the reactor calls
    {!instantiate}/{!invoke} per dispatch). *)

type isolation_tier = Sfi | Microvm
(** Which sandboxing mechanism a module runs under (Decision 5). [Sfi] (Software Fault
    Isolation) is wasmtime's own in-process WASM sandbox and is fully implemented by this module.
    [Microvm] is a real, spec'd contract for Task 8 (Firecracker-style hardware-virtualized
    isolation) that has no implementation yet — {!instantiate} raises a real, tested [Failure]
    for it rather than silently falling back to [Sfi] or accepting it as a no-op. [Sfi] is never
    a *weaker* baseline than [Microvm]; it is the mandatory floor every module runs under one way
    or another. *)

type host_functions = {
  read_materialized : merge_key:string -> bytes option;
  propose_write : bytes -> (unit, string) result;
  log : string -> unit;
}
(** The fixed host-function surface (Decision 3) a guest module may import, by name, from the
    WASM import namespace ["host"]. A guest may import any subset of ["log"],
    ["read_materialized"], ["propose_write"] — whichever it doesn't import is simply never
    callable from that guest. Importing from any other namespace, or an unrecognized name from
    ["host"], is an {!instantiate}-time error (see [loader.ml]'s top comment for exactly how the
    guest module's import section is read to build this). *)

type t
(** A single, live, already-instantiated guest module. Not reusable across separate logical
    invocations of a module — call {!instantiate} again for each one (Decision 5). *)

val instantiate : tier:isolation_tier -> module_bytes:string -> host:host_functions -> t
(** [module_bytes] is WAT text or a raw WASM binary (both accepted transparently — see
    [loader.ml]'s top comment for why); [host] backs whichever of {!host_functions}'s fields the
    guest module actually imports.

    [tier = Microvm] @raise Failure "Loader.instantiate: Microvm tier is not yet implemented
    (Task 8's own job)" — a real, tested error, not silent acceptance of an unbuilt capability.

    [tier = Sfi] applies wasmtime's own resource limits so a module cannot grow its linear memory
    past what it itself declares (enforced by wasmtime's core WASM semantics on every guest
    [memory.grow]) nor blow a generous, fixed guest call-stack bound (wasmtime's
    [max_wasm_stack] engine config). It does **not** apply true instruction-level fuel metering —
    fuel is entirely absent from the classic [wasm_c_api] this loader runs on (see [loader.ml]'s
    top comment for the full story, including a hard environment bug — an outdated CPU-feature-
    detection crate crashing on this box's own CPU — that had to be fixed before any of this
    could even be verified live at all); {!invoke} below documents the wall-clock-deadline
    containment used instead.

    @raise Failure if the module fails to compile/instantiate (e.g. malformed WAT/wasm, an
    import from an unsupported namespace or an unrecognized ["host"] function name, or a WASM
    validation error) — these are genuine setup failures, distinct from {!invoke}'s per-call
    [Error] result. *)

val invoke : t -> entrypoint:string -> arg:bytes -> (bytes, string) result
(** Calls the guest's exported function named [entrypoint] (resolved by name against the
    module's own export section — see [loader.ml]), passing [arg] and returning whatever bytes
    the guest's own result names (this task's ptr+len marshaling convention, documented in
    [loader.ml]).

    Returns [Error msg] — never raises — for: no such export, the named export isn't a function,
    the guest traps (including a genuine WASM trap, e.g. an out-of-bounds memory access), or the
    wall-clock containment deadline is exceeded (the closest real equivalent this loader has to
    "fuel exhausted", given no fuel API is available on the classic [wasm_c_api] surface this
    loader runs on — see [loader.ml]'s top comment). The call itself runs in a forked child
    process specifically so this containment is real: a guest that never returns is SIGKILLed on
    timeout, not merely abandoned in-process (an earlier, simpler same-process design was
    rejected after it reproducibly deadlocked the whole host process — see [loader.ml]). Host
    functions the guest calls during [invoke] (this task's own ["log"], potentially
    ["read_materialized"]/["propose_write"]) are relayed back to the real, caller-supplied
    {!host_functions} regardless of which process actually runs the guest, so their side effects
    are always observed by [invoke]'s own caller. The guest's own result bytes are read out of
    its linear memory by that same forked child, before it reports back — not by the parent
    afterwards, since guest memory is exactly as copy-on-write as everything else the fork
    duplicates, and only the child's own writes (its own return value; whatever
    ["read_materialized"]/["propose_write"]'s host-closure marshaling wrote into that memory
    during the call) are visible from inside it (see [loader.ml]'s [run_contained] for the real
    bug this caused and fixed the first time this loader actually returned non-empty guest
    results). Each [invoke] call costs a real `fork`, non-trivial relative to an in-process call
    — a real, measurable cost Task 6's reactor should account for, not assume away. *)
