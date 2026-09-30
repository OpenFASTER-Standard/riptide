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
    this task's own tests observe it fired at all), not a per-subscription policy choice. *)

val wrap_materialize_sink :
  t ->
  Riptide_batch_commit.Batch_commit.materialize_sink ->
  Riptide_batch_commit.Batch_commit.materialize_sink
(** Returns a sink whose [write ~merge_key v] first calls [inner.write ~merge_key v] --
    materialization is never skipped, delayed, or reordered by anything this function adds -- and
    then, for every module {!subscribe}d to [merge_key] (in subscription order; independently of
    each other, per this file's top comment), calls {!Loader.instantiate} fresh followed by
    {!Loader.invoke} [~entrypoint:"handle" ~arg:(Riptide.Value.canonical_encode v)] -- reusing
    this codebase's own existing, canonical [Value.value <-> bytes] wire convention (the same one
    {!Riptide_batch_commit.Batch_commit} itself encodes/decodes batches with) rather than
    inventing a second one just for this call.

    A module's own dispatch failing -- {!Loader.instantiate} raising (a bad tier, an over-large
    declared memory, an unsupported import), or {!Loader.invoke} returning [Error] (a protocol
    violation, a trap, a fuel timeout) -- is caught here, logged, and does not raise out of this
    [write]: it is treated exactly like a module that chose to do nothing this dispatch, not like
    a failure of {!wrap_materialize_sink} itself. A change on a [merge_key] with no subscribers is
    a total no-op beyond the inner [write] call -- no {!Loader.instantiate} is ever attempted. *)

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
