(** The reactor dispatch loop: wires subscribed, {!Admission}-verified WASM modules to real
    materialized-state changes flowing through {!Riptide_batch_commit.Batch_commit}'s own
    {!Riptide_batch_commit.Batch_commit.materialize_sink} (task-master Task 6, subtasks 6.1 and
    6.5).

    This is the module this whole plan's own {!Riptide_module} boundary (Tasks 1-5) exists to be
    pressure-tested against, per this repo's own [CLAUDE.md] "Expect the first extension mechanism
    to need real revision" -- every interface consumed below ({!Admission.verify}'s output,
    {!Loader.instantiate}/{!Loader.invoke}, {!Protocol.t}, {!Riptide_batch_commit.Batch_commit
    .materialize_sink}) is exercised here for real, wired end to end, not merely unit-tested in
    isolation the way Tasks 1-5's own test suites each did for their own module alone.

    {b The dispatch shape}: {!subscribe} records that a given {!Admission.verified_artifact}
    module wants to be invoked whenever a write lands at a given [merge_key];
    {!wrap_materialize_sink} returns a sink whose [write] calls the wrapped inner sink FIRST
    (materialization itself is never skipped, delayed, or reordered by anything below), then
    dispatches to every module subscribed to that same [merge_key] -- each in its own fresh
    {!Loader.instantiate} (Decision 5: one fresh {!Loader.t}, and therefore one fresh
    {!Protocol.checker}, per invocation, never reused), each with its own fresh, independent
    protocol state, and each fully isolated from every OTHER subscribed module's own success or
    failure: one module's trap, protocol violation, or {!Loader.instantiate}/{!Loader.invoke}
    failure is caught and logged internally, and never prevents a sibling module subscribed to the
    same key (or triggered by the same underlying commit) from running, and never raises out of
    {!wrap_materialize_sink}'s own [write] at all.

    {b Frozen as of task-master Task 7}: the Layer 0/Layer 2 boundary this module forms one half
    of (with {!Riptide_batch_commit.Batch_commit} the other) is no longer provisional -- Task 7
    closed the friction catalog the double-entry ledger (the real module this boundary was built
    to be pressure-tested against) surfaced. See
    docs/superpowers/specs/2026-10-01-layer2-boundary-revision-design.md's own "Boundary frozen"
    section for the closed catalog and what changed to close each item; further changes to this
    interface carry the same re-verification discipline as the rest of Layer 0. *)

type t
(** A reactor's own subscription table -- entirely in memory, not durable across process restarts;
    the caller (a future call site, out of this task's own scope to build -- see [subscribe]'s doc
    comment below) owns re-subscribing on startup from whatever durable configuration it keeps. *)

val create : unit -> t

val max_dispatch_depth : int
(** The enforced ceiling on how deeply {!wrap_materialize_sink}'s dispatch may nest inside itself
    (currently 8). Public, not an internal detail, because it is a real, observable limit on what a
    subscribed module can do: a module that proposes to its own subscribed key retriggers itself,
    and this is the bound at which that chain stops.

    {b Why a bound exists at all.} Reentrant dispatch is by design (see {!wrap_materialize_sink}) —
    a dispatched module's [~propose] is wired to a real
    {!Riptide_batch_commit.Batch_commit.propose}, which commits, materializes, and drives the very
    sink that dispatched it. Each live level holds a forked child process, two pipe file
    descriptors, and a freshly compiled WASM instance until the level below it returns, so an
    unconditionally self-proposing guest previously consumed processes and descriptors without any
    limit at all. Once this depth is already live, a further dispatch is REFUSED — logged with the
    responsible [merge_key] and the limit, and treated exactly like a module that chose to do
    nothing (see {!wrap_materialize_sink}: the inner sink's own [write] still ran first,
    unconditionally, so materialization is never what gets skipped here) rather than raised, since
    the code that would receive such an exception is the guest's own relayed host call, which has
    no way to act on it.

    {b Relation to {!Loader.fuel_budget_seconds}} (stated because it changed in the same fix wave
    that added this): while nested host-closure time was still charged against each outer guest's
    own fuel budget, deep nesting was crudely self-limiting — an outer guest was eventually
    SIGKILLed as a "runaway" and the chain collapsed from the outside in. That was itself a bug
    (a well-behaved guest reported as a containment failure after its write had already committed;
    see {!Loader.invoke}'s own doc comment), and fixing it removed the accidental bound along with
    it. This constant is now the only thing keeping the nesting finite.

    {b Known, disclosed residual gap: this is a bound, not a scheduler.} A legitimately long
    reaction chain deeper than this is refused, not deferred — the proper mechanism (queue a
    retriggered dispatch and run it at depth 1 once the current one returns) needs a real design of
    its own: ordering, fairness, durability across restarts, and what it would mean for the
    sequential-dispatch contract {!wrap_materialize_sink} documents as load-bearing. That is a
    future task's, not something this bound pretends to have solved. *)

val subscribe :
  t ->
  merge_key:string ->
  module_:Admission.verified_artifact ->
  protocol:Protocol.t ->
  read:(merge_key:string -> bytes option) ->
  propose:(bytes -> (unit, string) result) ->
  unit
(** [subscribe t ~merge_key ~module_ ~protocol ~read ~propose] registers [module_] to be invoked,
    on its exported ["handle"] entrypoint, every time {!wrap_materialize_sink}'s returned sink
    observes a write at [merge_key] -- possibly alongside other modules already subscribed to the
    same [merge_key], each independently (see this file's top comment).

    [module_]'s own bytes ([module_.local_path], per {!Admission.verified_artifact}) are read
    ONCE, right here, at subscribe time -- not re-read from disk on every later dispatch. This is
    a deliberate choice, not an oversight: {!Admission.verified_artifact} carries a verified PATH,
    not the verified bytes themselves (see this task's own report, "Boundary friction found", for
    why that mismatch exists and why reading once here is the right response to it) -- reading
    again on every dispatch would reopen a fresh TOCTOU window between {!Admission.verify}'s own
    check and every single invocation, not just once between verification and subscription.
    [module_.tier] governs every later {!Loader.instantiate} call this subscription drives, and
    [protocol] seeds a FRESH {!Protocol.checker} (via {!Loader.instantiate}'s own [~protocol]) on
    every single dispatch -- a module subscribed to a key that fires twice gets its protocol
    re-armed from [protocol]'s own initial state each time, not carried over from the previous
    dispatch, matching {!Loader}'s own "one fresh checker per {!Loader.instantiate}" contract.

    [read]/[propose] back {!Loader.host_functions}'s own [read_materialized]/[propose_write]
    fields for every dispatch of this one subscription -- the caller's responsibility to wire to a
    real {!Riptide_materialize.Materializer.read} and a real {!Riptide_batch_commit.Batch_commit
    .propose} call (against whatever {!Riptide_batch_commit.Batch_commit.t} handle that
    deployment's own [authorize] policy is attached to), the same erased-sink pattern
    {!Riptide_batch_commit.Batch_commit.materialize_sink}/[encryption_sink] already establish --
    this module has no opinion on which concrete materializer or handle a given subscription uses.
    {!Loader.host_functions}'s own [log] field is filled in internally by this reactor and cannot
    be customized per subscription -- nothing about a call here needs to, since a module's log
    output is this reactor's own operational concern (see {!For_testing.log_call_count} for how
    this task's own tests observe it fired at all), not a per-subscription policy choice. Every
    line this reactor itself emits -- both a dispatched module's own relayed [log] calls and this
    reactor's own dispatch-failure/dispatch-raised messages (see {!wrap_materialize_sink}) -- is
    tagged with the [merge_key] and [module_.local_path] responsible for it, so multiple modules
    subscribed to the same or different keys (the fan-out shape this reactor exists for) remain
    attributable in the log stream, not merged into one undifferentiated "[reactor] ..." line.

    {b Known, disclosed residual gap: dispatch is PER WRITE, not per merged-value CHANGE, and the
    guest's [arg] is the write's own payload, not the merged value.} (Review finding I4; the design
    spec's Decision 2 has been corrected to describe the real trigger condition, and the gap is named
    there as deliberately deferred work.) The spec originally said a module "is invoked when that
    key's {i merged} value changes." What actually happens is that
    {!wrap_materialize_sink}'s [write] fires once for every write landing at a subscribed
    [merge_key], and passes {b that write's own value} to the guest. Two consequences a subscribing
    caller has to know: nothing compares the merged accumulator before and after, so a write that
    merges to a value identical to the previous one still dispatches (a module needing
    "only act on real change" must dedupe itself); and the [arg] a guest receives is NOT current
    state. Live evidence rather than a hypothetical: [test/fixtures/counter.wat], the one real module
    built against this boundary, ignores [arg] entirely and re-reads its own key through
    [host.read_materialized] to obtain the merged value — that workaround exists because of this gap.
    Closing it needs a diff against the accumulator's prior value at the sink's own call site, which
    raises real questions (what "changed" means for an arbitrary lattice value; whether the sink needs
    read-before-write access it does not have) that belong to a future task's design, not to this
    mechanism as shipped.

    {b Known, disclosed residual gap: [~protocol] is supplied by YOU, and nothing checks it against
    the module.} (Review finding I5; the spec's Decision 4 has been corrected, and
    {!Admission.verify} discloses the same gap from the verification side.) The spec originally
    described the protocol as travelling with the module's own manifest, verified at admission. There
    is no manifest: [~protocol] is whatever this caller passes, {!Admission.verify} never looks for a
    protocol at all, and no check anywhere compares the one supplied here against what the module
    actually does. So a protocol here is a claim the SUBSCRIBER makes about the module, enforced
    faithfully against that claim — a protocol that permits more than the module should be allowed to
    do is enforced exactly as faithfully as a correct one. Concretely: the real trust boundary today
    is "whoever subscribes a module is trusted to describe its behavior honestly," which is weaker
    than "the verified artifact says what it may do." Note also that enforcement is per ENTRYPOINT
    call ({!Loader.invoke} steps the checker on the entrypoint name before entering the guest), not
    per host-function call — the guest's own [read_materialized]/[propose_write]/[log] calls are not
    individually checked, so a protocol cannot currently express a constraint like "no second
    [propose_write] in one dispatch."

    {b Known, disclosed residual gap: no per-dispatch amortization — every dispatch recompiles the
    module from its source bytes.} (Task 6's own boundary-friction item 2, sharpened by review finding
    M3 to say what actually happens rather than only "re-instantiates".) Each dispatch runs the full
    cost: [module_bytes] (WAT text, in every fixture here) through [wat_to_wasm], a fresh WASM module
    compile, a fresh instance, a fresh {!Protocol.checker}, and a real [fork] for containment
    ({!Loader.invoke}). Nothing is cached or pooled between dispatches, per module, per key, or
    process-wide — so a hot key fans out real compiles, not cheap invocations. Part of that is a
    deliberate safety property, not waste (Decision 5's "one fresh instance per invocation, no stale
    state between invocations", which any future cache has to preserve), and part is simply
    unamortized: a compiled-artifact cache would keep the property while removing the recompile. That
    is named, deferred performance work, not something the current shape pretends to have.

    {b Known, disclosed residual gap: a module trap is logged to stderr only.} (Review finding M4.)
    When a dispatched module traps, exhausts its wall-clock containment budget, or violates its
    protocol, this reactor writes an unstructured [Printf.eprintf] line (tagged with the [merge_key]
    and module path, see below) and moves on. The design spec's Error-handling section originally
    promised a structured event through {!Riptide_vsr.Replica}'s [?on_event] hook; that was never
    built, and was deliberately declined rather than bolted on here, because it is a Layer 0
    interface change and not a local one: [replica_event] is a documented CLOSED variant covering
    three concepts [replica.ml] itself classifies (a guest trap is not one), [replica.mli] exposes no
    way for anything outside that module to fire an event at all, and this reactor deliberately holds
    no {!Riptide_vsr.Replica.t} — it takes erased [~read]/[~propose] closures precisely so it has no
    opinion on which replica a subscription is wired to. A deployment that needs machine-readable
    module-failure signals today has to read this process's stderr; a future task owns deciding
    whether such events belong on Layer 0's replica-event channel or on a reactor-owned one.

    {b CLOSED by task-master Task 7 (the Layer 0/Layer 2 boundary revision): a [~propose] closure
    wired to a FIXED {!Riptide_batch_commit.Batch_commit.t} used to stop working silently when the
    primary moved, with nothing here to warn you.} (Task 6's own boundary friction, item 4; final
    whole-branch review finding I9. Kept rather than deleted because the hazard itself is still
    real -- what Task 7 shipped is the way to detect and report it, not its removal; a caller that
    skips the check below gets exactly the pre-Task-7 behaviour described here.) A
    {!Riptide_batch_commit.Batch_commit.t} is built over one
    {!Riptide_vsr.Replica.t}, and {!Riptide_batch_commit.Batch_commit.propose} through a replica
    that is not currently the primary in [Normal] status is a documented SILENT NO-OP -- not an
    error, not a [Deny], no counter, nothing. So the natural way to wire this parameter (build one
    handle at subscribe time, close over it) is correct exactly until the first view change, after
    which every write the guest proposes vanishes without trace. Confirmed live while building the
    first real module against this boundary: a ledger's legs batch, proposed correctly by a guest
    that ran correctly, never converged because a storm-driven view change had moved the primary and
    the closure was still holding a handle on the old one. A caller must re-derive the current
    primary on every single proposal, as a real client would, rather than caching one -- and because
    [propose]'s own result type here is [(unit, string) result], a closure that finds no live primary
    had to decide between reporting [Error] (which the guest will see as a failure it cannot
    distinguish from a real rejection) and [Ok] (which claims something happened). Neither was right.
    This reactor still cannot fix it from the inside: it deliberately holds no
    {!Riptide_vsr.Replica.t} at all.

    {b What Task 7 shipped, and what a [~propose] closure must therefore do}: Layer 0 now exposes
    {!Riptide_batch_commit.Batch_commit.is_primary} (design spec Decision 5), the predicate a
    closure previously had to independently rediscover and reproduce. Check it IMMEDIATELY BEFORE
    every {!Riptide_batch_commit.Batch_commit.propose} call -- never once at {!subscribe} time,
    never cached, since primary/view status can change between any two calls -- and when it is
    [false], return [Error "not primary, retry"] WITHOUT calling [propose] at all. That exact
    [Error] string is the shipped answer to the "neither [Error] nor [Ok] is right" dilemma above:
    the guest still sees only a nonzero status byte, but the refusal is now distinguishable from a
    real rejection by its reason, attributable in the log stream, and -- crucially -- a write is no
    longer silently swallowed by a no-op [propose] it never should have reached.
    [lib/ledger/]'s own harness wires it exactly this way; see
    [Riptide_ledger.Accumulator.handle_guest_decision]'s doc comment for why ONE up-front check
    covers every outcome that has something to lose, and [test/test_ledger_dst_load.ml]'s own
    non-primary scenario for the live evidence that the closure reports
    [Error "not primary, retry"] rather than dropping the dispatch.

    {b Residual, disclosed at {!Riptide_batch_commit.Batch_commit.is_primary} itself rather than
    restated here}: the check-then-[propose] pair is not atomic, and [is_primary] does not predict
    [propose]'s third (in-memory-log-gap) guard. So this narrows the window in which a closure
    proposes blind; it does not close it. A durable, acknowledged propose path remains a later
    task's job (see the fire-and-forget paragraph below).

    {b CLOSED by task-master Task 7 (the Layer 0/Layer 2 boundary revision): a write a guest
    proposes can still be silently DISCARDED after [~propose] returned [Ok], and re-triggering the
    dispatch that produced it is still the only recovery -- what Task 7 added is the missing
    CONTRACT that makes relying on that recovery sound, stated below as an obligation of this
    interface rather than left for each module author to rediscover.} (Task 6's own boundary
    friction, item 5; final whole-branch review finding I9. Item 5 offered two possible closures --
    a durable, acknowledged propose path, or "at minimum a documented contract that a dispatched
    guest must be idempotent under re-dispatch" -- and Task 7 shipped the second; the first is
    still a later task's, see the fire-and-forget paragraph below.) A batch
    that has been appended but not yet committed is exactly what a VSR view change is entitled to
    throw away -- correctly, since nobody could yet have assumed it durable -- and nothing in this
    reactor, in {!Riptide_batch_commit.Batch_commit}, or anywhere else re-proposes it. Observed for
    real while building the first module against this boundary (a legs batch dropped across all
    three replicas, entries 9 -> 8, after a view change landed in that window). What makes recovery
    possible at all is an accident of the gap documented above: because dispatch fires on every
    materialize of a subscribed key rather than on a merged-value change, re-materializing the
    already-committed write that triggered the guest the first time dispatches it again, and the
    guest proposes again. That means correctness here depends on a guest being safely
    re-dispatchable.

    {b The contract, stated here because this is where a [~propose] closure author reads it.} A
    dispatched guest, and the host closure wired to its [~propose], MUST be idempotent under
    re-dispatch: the same underlying committed write may drive the same guest arbitrarily many
    times, and every run after the first must reach the SAME externally-visible outcome as the
    first, not merely a locally-plausible one. The subtlety that makes this non-obvious is that a
    guest re-run later sees LATER materialized state: re-running against a since-changed balance can
    legitimately reach a DIFFERENT decision and move money no client ever asked to move (the ledger
    module's own Critical finding, reproduced for real). So "idempotent" here is not "the write is
    harmless to replay" -- it is "the DECISION is pinned to its first committed form, and only the
    re-proposal of that already-pinned form replays." The way to satisfy it is to make the first
    COMMITTED outcome authoritative and re-derive every later run from it: query the committed log
    for a decision already recorded under this request's own idempotency key
    ({!Riptide_batch_commit.Batch_commit.committed_writes_for}, exported by Task 7 for exactly this)
    and, if one is there, rebuild the batch from THAT record rather than from this dispatch's own
    bytes. Explicitly not a host-side in-memory table: the ledger module's first attempt was one,
    and a process's own memory is not a sound source of truth for a durable fact -- a restart lost
    every decline it held, which is precisely the bug that made the committed-log query the shipped
    answer. See [Riptide_ledger.Accumulator.handle_guest_decision] for the worked,
    tested-against-a-view-change implementation of this contract.

    {b Known, disclosed residual gap: [~propose] is fire-and-forget from this reactor's own
    perspective.} {!wrap_materialize_sink} calls [propose] and relays only the [Ok]/[Error] shape
    it returns back to the guest as a status byte -- it does not await, retry, or otherwise confirm
    that whatever the closure did on the other end (e.g. a real
    {!Riptide_batch_commit.Batch_commit.propose} call, itself already documented as fire-and-forget
    -- see {!Riptide_batch_commit.Batch_commit.propose}'s own doc comment) actually, durably
    committed. A caller wiring [~propose] against a real {!Riptide_batch_commit.Batch_commit.t}
    handle has no built-in signal from either module for whether one specific proposed write
    landed; inferring it indirectly (e.g. via
    {!Riptide_batch_commit.Batch_commit.authorization_denials}'s own before/after delta around one
    call, the technique this task's own test suite uses) is sound ONLY because
    {!wrap_materialize_sink}'s own dispatch to every subscriber of a given [merge_key] is genuinely
    SEQUENTIAL, never concurrent -- see {!wrap_materialize_sink}'s own doc comment, which states
    this as an actual, load-bearing contract of this module, not an incidental implementation
    detail. A caller building a per-call delta like this must not assume it would stay sound if a
    future version of this function ever dispatched subscribers concurrently. A deployment that
    genuinely needs to know whether a specific proposed write committed needs its own out-of-band
    signal (e.g. reading back through {!Riptide_batch_commit.Batch_commit.committed_envelopes}, or
    a future, real acknowledgment mechanism -- {!Riptide_batch_commit.Batch_commit.propose}'s own
    doc comment marks that "Task 9's own job") -- this reactor provides none itself. *)

val wrap_materialize_sink :
  t ->
  Riptide_batch_commit.Batch_commit.materialize_sink ->
  Riptide_batch_commit.Batch_commit.materialize_sink
(** Returns a sink whose [write ~merge_key ~idempotency_key ~position ~actor ~causation ~correlation
    v] first calls [inner.write] with every one of those arguments relayed VERBATIM -- nothing here
    recomputes, re-derives, drops or reorders any of the write-identity parameters
    {!Riptide_batch_commit.Batch_commit.materialize_sink}'s own [write] carries, and
    materialization is never skipped, delayed, or reordered by anything this function adds -- and
    then, for every module {!subscribe}d to [merge_key], in subscription order, ONE AT A TIME --
    {b sequentially, never concurrently; this is a real, load-bearing contract of this function,
    not merely today's implementation detail, see [subscribe]'s own "Known, disclosed residual
    gap" paragraph for exactly what a caller's own code correctly depends on this for} -- calls
    {!Loader.instantiate} fresh followed by {!Loader.invoke} [~entrypoint:"handle"
    ~arg:(Riptide.Value.canonical_encode v)] -- reusing this codebase's own existing, canonical
    [Value.value <-> bytes] wire convention (the same one {!Riptide_batch_commit.Batch_commit}
    itself encodes/decodes batches with) rather than inventing a second one just for this call.
    Each dispatch is otherwise fully independent of every other (per this file's top comment):
    sequential ordering is a scheduling fact, not a data or control dependency between modules.

    A module's own dispatch failing -- {!Loader.instantiate} raising (a bad tier, an over-large
    declared memory, an unsupported import), or {!Loader.invoke} returning [Error] (a protocol
    violation, a trap, a fuel timeout) -- is caught here, logged, and does not raise out of this
    [write]: it is treated exactly like a module that chose to do nothing this dispatch, not like
    a failure of {!wrap_materialize_sink} itself. [Out_of_memory]/[Stack_overflow] are the one
    exception: both are re-raised rather than caught, matching [loader.ml]'s own [cleanup]
    precedent in this exact codebase -- they signal the process itself is in trouble, not a normal
    per-module failure to log and continue past. A change on a [merge_key] with no subscribers is
    a total no-op beyond the inner [write] call -- no {!Loader.instantiate} is ever attempted.

    Dispatch may reenter this same [write] (a module's [~propose] is typically wired to a real
    {!Riptide_batch_commit.Batch_commit.propose}, which commits, materializes, and drives this sink
    again), and that nesting is bounded: once {!max_dispatch_depth} levels are already live, a
    further dispatch is refused and logged rather than attempted. See {!max_dispatch_depth} for the
    bound's own derivation and its disclosed limitation. The inner [write] above is never what gets
    refused -- that call is unconditional at every depth.

    {b COMPOSITION ORDER IS LOAD-BEARING: any
    {!Riptide_batch_commit.Batch_commit.deduplicate} gate belongs INSIDE this wrapper, never
    outside it} (Task 7, Task 4's own review Critical 1 -- a live-reproduced liveness bug, not a
    stylistic preference; {!Riptide_batch_commit.Batch_commit.deduplicate} states the same rule
    from the other side). [deduplicate] makes a sink exactly-once per committed write by skipping
    the wrapped sink's [write] ENTIRELY for a write it has already seen. Placed OUTSIDE the sink
    this function returns, it therefore skips the DISPATCH too -- and re-dispatch is the one and
    only recovery path a batch that a VSR view change discarded before it committed has (see the
    item-5 paragraph under {!subscribe}). Observed consequence of getting it backwards: a transfer
    whose legs batch was discarded pre-commit became PERMANENTLY unrecoverable. Nothing corrupted
    and no money moved wrongly, which is exactly what makes it easy to ship unnoticed. Correct:
    {[
      let sink =
        Reactor.wrap_materialize_sink reactor
          (Batch_commit.deduplicate ~watermark_store (Accumulator.materialize_sink ...))
    ]}
    i.e. the gate wraps the inner, business-logic sink that genuinely needs exactly-once semantics,
    and this dispatch-carrying wrapper stays outermost so dispatch fires on every materialize call
    unconditionally. This function supplies no gate of its own and must not be given one: dispatch
    being unconditional at every call is the property the recovery path rests on. *)

module For_testing : sig
  val log_call_count : unit -> int
  (** How many times ANY dispatched module's own [host.log] import has been called, over this
      process's lifetime -- shaped like {!Riptide_batch_commit.Batch_commit.authorization_denials}
      /[materialize_write_failures]: a monotonic, process-lifetime count, never reset. The useful
      reading is a delta between two samples taken around a call of interest, not an absolute
      value read in isolation. Exists only so this task's own tests can observe that a dispatched
      module's [handle] entrypoint genuinely ran (the same "log call as an observable side effect"
      technique Task 3's own tests already use directly against {!Loader}), since [log] itself is
      filled in internally by {!subscribe} and is not otherwise exposed to a caller. *)
end
