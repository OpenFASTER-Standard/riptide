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
    {!wrap_materialize_sink}'s own [write] at all. *)

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
(** Returns a sink whose [write ~merge_key v] first calls [inner.write ~merge_key v] --
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
    refused -- that call is unconditional at every depth. *)

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
