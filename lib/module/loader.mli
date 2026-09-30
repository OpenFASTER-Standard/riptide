(** WASM module loading, host-ABI wiring, and SFI isolation (Task 5, subtask 3 / Decision 5).

    One fresh {!t} per {!instantiate} call, never reused across invocations — separate linear
    memory, no stale state carried between invocations, by construction (Decision 5). The
    guest-facing ABI (Decision 3) is a small, fixed, hand-rolled calling convention documented at
    the top of [loader.ml], not the WebAssembly Component Model (no OCaml runtime supports it
    yet).

    Every {!t} also owns its own, private {!Riptide_module.Protocol.checker} (Task 4), created
    once at {!instantiate} time and advanced by {!invoke} on every call — {!invoke} rejects a
    call that violates the declared {!Riptide_module.Protocol.t} outright, before the guest is
    ever dispatched into. Since {!instantiate} already creates a fresh {!t} (and therefore a
    fresh checker) per call, two concurrent invocations of the same underlying module never share
    protocol state, with no extra locking needed.

    Consumed by Task 6 (the reactor calls {!instantiate}/{!invoke} per dispatch). *)

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

val fuel_budget_seconds : float
(** The wall-clock containment budget one {!invoke} call gives the guest, in seconds — this
    loader's own stand-in for wasmtime's per-instruction fuel metering, which is entirely absent
    from the classic [wasm_c_api] surface it runs on (see [loader.ml]'s top comment). Exposed
    rather than kept private for two real reasons, not merely for tests: a caller that dispatches
    guests reentrantly needs it to reason about its own bound (see
    {!Riptide_module.Reactor.max_dispatch_depth}, whose own documented derivation cites this
    value), and this loader's own regression test for "host-closure time is not guest time"
    (below) has to know the budget it is deliberately exceeding.

    {b What this budget does and does not measure.} It bounds GUEST execution time only. Time the
    PARENT spends inside a host closure the guest called out to ([read_materialized]/
    [propose_write]/[log], all entirely caller-supplied code — which may itself be arbitrarily
    slow, and in this plan's own reactor genuinely IS: a relayed [propose_write] can drive a whole
    nested {!Riptide_batch_commit.Batch_commit.propose}, materialization, and further module
    dispatches before returning) is explicitly NOT charged against it: the guest is blocked
    waiting for that response the entire time and is executing nothing of its own. See
    {!invoke}'s own doc comment for the real bug this closed. *)

val instantiate :
  tier:isolation_tier -> module_bytes:string -> host:host_functions -> protocol:Protocol.t -> t
(** [module_bytes] is WAT text or a raw WASM binary (both accepted transparently — see
    [loader.ml]'s top comment for why); [host] backs whichever of {!host_functions}'s fields the
    guest module actually imports.

    [protocol] (Task 4) is the session-type FSM (see {!Riptide_module.Protocol}) every later
    {!invoke} call on the returned {!t} is checked against, by entrypoint name — [instantiate]
    itself merely calls {!Riptide_module.Protocol.start} once, on this argument, to seed the
    returned [t]'s own private checker; it does not otherwise validate or use [protocol] at
    instantiate time (a module with no exports the protocol will ever legally permit still
    instantiates successfully — that's an {!invoke}-time concern, not a setup failure). This is
    required, not optional, even for tiers/paths where no {!invoke} call will ever actually
    happen (e.g. [tier = Microvm] below, or the memory-limit/import-rejection failures that abort
    before any guest call could occur) — every {!t} unconditionally owns a checker from the
    moment it exists, so there is never a window where {!invoke} could be called against a [t]
    that has none.

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

    Task 4: BEFORE any of that — before the export lookup, before touching guest memory, before
    the guest is dispatched into at all — [entrypoint] is checked against [t]'s own protocol
    checker (seeded from {!instantiate}'s [~protocol] argument) via
    {!Riptide_module.Protocol.step}. If the declared protocol has no transition for [entrypoint]
    from the checker's current state, [invoke] returns that [Error] immediately and the guest
    never runs — not even far enough to discover it has no such export — matching this
    codebase's own "guard failure ⇒ total no-op" convention (see {!Riptide_module.Protocol.step}'s
    own doc comment for the exact error shape). On success, [t]'s checker is advanced immediately,
    before the now-permitted call actually executes; the protocol governs which calls a guest is
    permitted to be dispatched with; it does not roll back if the dispatched call then itself
    fails for an unrelated reason (a trap, a fuel timeout, etc.) — the same way a session-typed
    peer sending a legal message doesn't un-send it just because the recipient then errors out
    handling it. Each {!t} owns its own checker, seeded once at {!instantiate} time and never
    shared with any other {!t} — two concurrent invocations of the very same underlying module
    (two separate {!instantiate} calls) therefore track their own, fully independent protocol
    state, with no locking needed (see
    [test_two_concurrent_invocations_of_the_same_module_do_not_share_protocol_state] in
    test_module_loader.ml).

    Returns [Error msg] — never raises — for: a protocol violation (above), no such export, the
    named export isn't a function, the guest traps (including a genuine WASM trap, e.g. an
    out-of-bounds memory access), or the
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

    {b The containment deadline charges GUEST time only} ({!fuel_budget_seconds}). Time this
    parent process spends inside a host closure the guest called out to — and, transitively,
    inside anything that closure itself drives — is credited back to the deadline rather than
    counted against it, because the guest is blocked on the relay response for every microsecond
    of it and is executing nothing of its own. This is not a fairness nicety: charging it produced
    a real misbehavior (found by this plan's own final whole-branch review, finding I2), because
    this plan's reactor wires a genuine {!Riptide_batch_commit.Batch_commit.propose} into
    ["propose_write"] — authorization checkpoint, VSR commit, materialization, and every further
    module dispatch that materialization retriggers, all inside one relayed host call. A
    well-behaved guest was therefore SIGKILLed and reported "fuel exhausted" AFTER the write it
    proposed had already been committed by the very closure whose duration triggered the report,
    handing its caller a containment failure for a call that in fact succeeded.

    {b Known, disclosed residual gap: a host closure's own duration is not bounded by anything
    here.} A caller-supplied ["log"]/["read_materialized"]/["propose_write"] that blocks forever
    blocks this supervision loop forever, and no deadline in this module interrupts it. That is
    deliberate, not an oversight this fix left behind: those closures are the CALLER's own code
    running in the PARENT process — not the untrusted guest this loader exists to contain — and
    abandoning one mid-flight would mean unilaterally walking away from an operation the caller may
    already have made durable (a committed {!Riptide_batch_commit.Batch_commit.propose} is exactly
    that case). A caller that needs its own host-side timeout owns imposing it inside its own
    closure. The related hazard this fix DOES close a bound on is unbounded reentrant nesting of
    such calls, and it is bounded where it is created rather than here — see
    {!Riptide_module.Reactor.max_dispatch_depth}.

    The forked child is always reaped and both of its parent-side pipe file descriptors always
    closed, on every exit path — including a child that dies via an uncaught OS signal (a real,
    demonstrated possibility on this exact codebase: [loader.ml]'s top comment point 0 already
    found `libwasmtime`'s own Rust internals capable of process-aborting panics) rather than
    through its own clean reporting; an exception raised from the parent's own supervision step
    itself — whether from [Unix.select] or from a host callback (this task's own
    ["log"]/["read_materialized"]/["propose_write"], entirely caller-supplied code this loader
    does not control); AND a SECOND asynchronous signal landing mid-cleanup itself (masked via
    [Unix.sigprocmask] around the actual kill/waitpid/close/close sequence, with [cleanup]
    guaranteed by construction to never propagate anything out of it besides [Out_of_memory]/
    [Stack_overflow], which are deliberately let through rather than silently converted, per
    OCaml convention); AND a signal landing in the one instant that masking cannot itself cover,
    before the mask takes hold, which the cleanup sequence survives by being retried until it has
    genuinely run start-to-finish rather than by yet another, narrower guard (its every step —
    kill, waitpid, close, close — is idempotent by design, so retrying is always safe, and it
    claims completion only after actually completing). This took four real fix rounds to actually
    hold for every path, not one or two — each prior round's own regression test passed while a
    further gap the review kept finding stood; see [loader.ml]'s [supervise_child], [step], and
    [cleanup] for the full history, all four confirmed via a live, real-signal reproduction (a
    real, permanently-armed SIGALRM in this same test suite, not a synthetic stand-in) at each
    round, and the fourth's own residual (the sub-instruction instant at [cleanup]'s own entry,
    before any guard of its own can exist) disclosed in full there rather than glossed. No exit
    path leaks a zombie process or a file descriptor.

    **Known, disclosed, deliberately-not-engineered-around interaction**: this test suite's own
    external per-test watchdog (`test_riptide.ml`'s [Suite_timeout], a SIGALRM-driven safety net
    entirely separate from and unrelated to this loader's own [fuel_budget_seconds]) firing while
    execution is inside [invoke] gets caught by the same catch-all that handles every other
    asynchronous signal here, and silently converted to an ordinary [Error] result instead of
    surfacing as the loud "this test hung" failure it's meant to be. This is a real interaction
    worth knowing about if a future test on this loader ever times out unexpectedly quietly
    instead of loudly, but it is specific to this one test suite's own harness design, not
    something [loader.ml] should special-case — it has no business knowing about a test-only
    exception type, and doing so would mean reaching outside its own module boundary to
    accommodate one specific caller's testing infrastructure. *)

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

  val simulate_repeated_signals_during_cleanup :
    unit -> (bytes, string) result * int * Unix.file_descr * Unix.file_descr
  (** Exists only for this task's own regression test proving the same guarantee holds against a
      SECOND asynchronous signal landing mid-[cleanup] itself (not just mid-[step], which
      {!simulate_an_exception_mid_step} already covers) — arms a real, rapidly and repeatedly
      firing [SIGALRM] (the same signal this test binary's own suite-wide watchdog uses, reused
      here deliberately rather than a synthetic one, for a faithful live reproduction) around an
      entire contained call, then restores the exact previous handler/itimer state regardless of
      outcome so it doesn't disturb that watchdog for whatever test runs next. Not part of the
      guest-execution API — Task 4/6 must never call this. Same return shape and same two
      independent checks ([Unix.kill pid 0] / [Unix.close]) as {!simulate_child_death_mid_message}
      above. *)

  val simulate_signal_in_cleanups_pre_mask_window :
    unit -> (bytes, string) result * int * Unix.file_descr * Unix.file_descr
  (** Exists only for this task's own regression test proving the same guarantee holds against
      the one instant masking the cleanup sequence could not itself cover (round 4): a real
      asynchronous signal landing after [cleanup] has entered its own guard but before its
      [Unix.sigprocmask] has taken hold, which previously left kill/waitpid/close/close entirely
      un-run behind a normal-looking result with no exception raised anywhere — the only one of
      this loader's four reentrancy rounds that was silent rather than loud. Arms the same real,
      repeatedly-firing [SIGALRM] as {!simulate_repeated_signals_during_cleanup} and additionally
      widens that specific window once, so the signal is certain to land in it; restores the exact
      previous handler/itimer state (and clears the widening) regardless of outcome. Not part of
      the guest-execution API — Task 4/6 must never call this. Same return shape and same two
      independent checks ([Unix.kill pid 0] / [Unix.close]) as {!simulate_child_death_mid_message}
      above. *)
end
