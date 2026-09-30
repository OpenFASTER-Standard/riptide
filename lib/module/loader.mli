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

    [tier = Sfi] applies a REAL, host-enforced linear-memory page limit at instantiate time — not
    merely the guest module's own self-declared maximum, which is under full guest control and
    enforces nothing against an adversarial module on its own (wasmtime's ordinary [memory.grow]
    honors a hostile guest's own multi-gigabyte self-declared maximum exactly as faithfully as a
    well-behaved one's small one). [instantiate] parses the module's own binary memory section
    directly (see [loader.ml]'s [check_memory_limit]) and @raise Failure if its declared maximum
    exceeds a fixed cap (1024 pages / 64 MiB — see [loader.ml]'s [memory_pages_cap] for the one-
    line justification), or if it declares no maximum at all (unbounded growth is itself a
    violation, not a pass). It also blows a generous, fixed guest call-stack bound (wasmtime's
    [max_wasm_stack] engine config). It does **not** apply true instruction-level fuel metering —
    fuel is entirely absent from the classic [wasm_c_api] this loader runs on (see [loader.ml]'s
    top comment for the full story, including a hard environment bug — an outdated CPU-feature-
    detection crate crashing on this box's own CPU — that had to be fixed before any of this
    could even be verified live at all); {!invoke} below documents the wall-clock-deadline
    containment used instead.

    @raise Failure if the module fails to compile/instantiate (e.g. malformed WAT/wasm, an
    import from an unsupported namespace or an unrecognized ["host"] function name, a declared
    memory maximum exceeding the cap or missing entirely, or a WASM validation error) — these
    are genuine setup failures, distinct from {!invoke}'s per-call [Error] result. *)

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
    — a real, measurable cost Task 6's reactor should account for, not assume away.

    The forked child is always reaped and both of its parent-side pipe file descriptors always
    closed, on every exit path — including a child that dies via an uncaught OS signal (a real,
    demonstrated possibility on this exact codebase: [loader.ml]'s top comment point 0 already
    found `libwasmtime`'s own Rust internals capable of process-aborting panics) rather than
    through its own clean reporting, AND including an exception raised from the parent's own
    supervision step itself — whether from [Unix.select] (confirmed live by a real, permanently-
    armed test-suite watchdog firing mid-[select]) or from a host callback (this task's own
    ["log"]/["read_materialized"]/["propose_write"], entirely caller-supplied code this loader
    does not control). This took two real fix rounds to actually hold for every path, not one —
    the first left the second gap (an unguarded [select]/host-callback) standing; see
    [loader.ml]'s [supervise_child] and [step] for the full history. No exit path leaks a zombie
    process or a file descriptor. *)

module For_testing : sig
  val simulate_child_death_mid_message :
    unit -> (bytes, string) result * int * Unix.file_descr * Unix.file_descr
  (** Exists only for this task's own regression test proving the "no zombie/fd leak, ever"
      guarantee documented on {!invoke} above holds even on one path nothing in the public
      ["host"]-import/guest-execution API alone can organically trigger: a contained call's
      forked child dying (here, simulated by a bare child that just closes its pipe) before it
      ever completes a message, the same shape an uncaught OS signal produces. Not part of the
      guest-execution API — Task 4/6 must never call this. Returns the containment result
      (always [Error], never raises), the dead child's own pid, and the parent's own two
      pipe file descriptors, so the test can independently confirm both real reaping
      ([Unix.kill pid 0] failing with [ESRCH], not merely succeeding on an unreaped zombie) and
      real fd closure ([Unix.close] on either failing with [EBADF], not silently succeeding on
      a still-open descriptor). *)

  val simulate_an_exception_mid_step :
    unit -> (bytes, string) result * int * Unix.file_descr * Unix.file_descr
  (** Exists only for this task's own regression test proving the same guarantee holds on the
      OTHER path nothing in the public API can organically trigger: an exception raised from
      inside the parent's own supervision step (here, a caller-supplied ["log"] host closure
      that deliberately raises — the same code path an exception surfacing from [Unix.select]
      itself, e.g. a real, permanently-armed test-suite watchdog firing mid-call as this task's
      own code review reproduced live, goes through too). Not part of the guest-execution API —
      Task 4/6 must never call this. Same return shape and same two independent checks
      ([Unix.kill pid 0] / [Unix.close]) as {!simulate_child_death_mid_message} above. *)
end
