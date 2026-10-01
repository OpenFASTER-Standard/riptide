(** The ledger module's HOST half: the state and logic that sit on the OCaml side of the WASM
    guest, between {!Riptide_module.Reactor}'s dispatch and
    {!Riptide_batch_commit.Batch_commit}'s commit/materialize machinery.

    Three things live here, and they live here rather than in a test file because every one of
    them is load-bearing for correctness rather than for driving a test (final whole-branch review,
    finding I3 -- all of this previously existed only as ~50 lines duplicated verbatim across two
    test files, with a correctness guard no interface documented anywhere):

    - {!handle_guest_decision} -- the host side of the guest's [propose_write], and the one place
      a request's accept/decline decision is ever made final (finding C1).
    - {!materialize_sink} -- the host side of
      {!Riptide_batch_commit.Batch_commit.materialize_sink}, which is what actually turns committed
      {!Schema.transfer_leg}s into account BALANCES. Without this, the ledger is only a log of
      legs; the thing that makes it a ledger is here.
    - {!read_for_guest} -- the host side of the guest's [read_materialized], i.e. the read half of
      {!Wire}'s byte convention.

    All three are parameterised by erased closures over the caller's own materializer rather than
    functored over a {!Riptide_lattice.Lattice_intf.S}/{!Riptide_storage.Kv_store_intf.S}, matching
    the same "closure over an erased capability" shape
    {!Riptide_batch_commit.Batch_commit.materialize_sink} itself already uses, and for the same
    reason: this library has no business knowing which lattice or KV backend a given deployment
    materializes through. *)

type t
(** One ledger module instance's own host-side state. Create one per deployment (per
    {!Riptide_module.Reactor} subscription, in practice) and keep it for that instance's lifetime:
    both the first-decision-wins table {!handle_guest_decision} consults and the
    already-applied-legs table {!materialize_sink} consults live in here, so sharing one [t]
    between the propose side and the materialize side of the same ledger is required, not merely
    convenient.

    {b In-memory, and NOT durable across a process restart.} Stated plainly because it bounds
    exactly how much of finding C1 this closes: within one process's lifetime a decision can never
    flip, which is what makes the bug unreachable via every idiom that actually triggered it (the
    empty-writes drain, {!Riptide_batch_commit.Batch_commit.propose}'s own
    unconditional-on-retry materialize step, {!Riptide_batch_commit.Batch_commit.materialize_up_to}
    -- all of which re-dispatch an already-committed request inside a running process). A restart
    starts with an empty table, so a request whose DECLINE was recorded only here, and whose
    "ledger.requests" write is then re-materialized after the restart against a since-grown
    balance, could still be decided afresh. Making the decision durable rather than merely
    process-stable means committing it to the replicated log as its own write shape -- a real
    extension of this module's schema, and a decision about what a module may durably record that
    belongs with the Layer 0/Layer 2 boundary revision (task-master Task 7), not smuggled in
    here. *)

val create : unit -> t

val balance_delta : Schema.transfer_leg -> int64
(** [balance_delta leg] is the SIGNED amount [leg] moves its own {!Schema.transfer_leg.this_account}
    by: [-amount] for {!Schema.Debit}, [+amount] for {!Schema.Credit}. The single place that
    derivation lives -- a leg stores a positive magnitude and a role, never a signed amount (see
    {!Schema.transfer_leg}). *)

val decision : t -> request_id:int64 -> bool option
(** [decision t ~request_id] is [Some accepted] if a decision has ever been recorded for
    [request_id] through {!handle_guest_decision}, [None] if that request has never been decided.
    Once [Some _], this never changes for the lifetime of [t] -- that immutability IS the fix for
    finding C1. *)

val handle_guest_decision :
  t ->
  actor:Riptide.Envelope.actor_id ->
  propose:(idempotency_key:string -> Riptide_batch_commit.Batch_commit.write list -> unit) ->
  bytes ->
  (unit, string) result
(** [handle_guest_decision t ~actor ~propose decision_bytes] is the host side of the guest's
    [propose_write] host function -- wire this as {!Riptide_module.Reactor.subscribe}'s
    [~propose], with [propose] itself calling
    {!Riptide_batch_commit.Batch_commit.propose} against whatever handle and [~materialize] sink
    that deployment uses. [Error] (relayed to the guest as a nonzero status byte) if
    [decision_bytes] is not a well-formed {!Wire.decision_bytes}-byte decision payload; [Ok ()]
    otherwise, whatever the decision turns out to be -- a declined transfer is a normal outcome,
    not an error.

    {b The first decision ever recorded for a [request_id] is final, and that is the whole point
    of this function} (final whole-branch review, finding C1 -- a Critical). Concretely:

    - {b Never decided before.} The decision is recorded. If ACCEPTED, the two legs
      {!Legs.decision_of_bytes} built are proposed, as one atomic batch, under
      {!Schema.transfer_idempotency_key} of the request's own [request_id]. If DECLINED, nothing
      is proposed and nothing else happens -- but the decline is now on record.
    - {b Already decided DECLINED.} Nothing is proposed, ever, no matter what this dispatch
      decided. This is the case the bug lived in: the guest's decline previously left no trace
      anywhere, so any later re-materialization of the same already-committed "ledger.requests"
      write re-dispatched the guest against a CURRENT balance that may since have grown, it
      legitimately decided ACCEPT, and the host committed a transfer that no client ever asked for
      twice. Re-materialization is not an exotic act -- it is three separate documented idioms (see
      {!t}'s own note), one of which {!Riptide_batch_commit.Batch_commit.propose} performs
      unconditionally on every retry.
    - {b Already decided ACCEPTED.} The legs are re-proposed, from the ORIGINALLY RECORDED request
      rather than from this dispatch's own bytes, under the same idempotency key as before.

    {b Why an already-accepted request re-proposes rather than doing nothing}, since "ignore any
    later dispatch" would be the simpler rule: a legs batch that has been appended but not yet
    committed is exactly what a VSR view change is entitled to discard, and nothing else in this
    system ever re-proposes it -- so re-triggering the dispatch that produced it is the only
    recovery path there is, and it is a real one, exercised for real by this module's own DST test.
    Re-proposing is safe on both counts that matter: under the same idempotency key
    {!Riptide_batch_commit.Batch_commit.propose} skips re-appending a batch already in the log, and
    the sink below will not re-apply a leg it has already folded into a balance. Taking the legs
    from the recorded request makes this strictly STRONGER than merely pinning the accept/decline
    bit, not a weakening of it: a later dispatch can change neither the decision nor the amount or
    accounts the transfer moves.

    [actor] is the identity both legs are proposed under, and is recorded inside each leg's own
    payload as well (see {!Schema.transfer_leg}'s [actor] field). Each batch's
    [causation]/[correlation] are derived deterministically from its own idempotency key, so a
    re-proposal is byte-identical to the original rather than merely equivalent. *)

val prevented_flips : t -> int
(** [prevented_flips t] is how many times a dispatch has produced a decision for a [request_id]
    that already had one AND DISAGREED with it -- i.e. how many times the first-decision-wins rule
    above has actually prevented a request's outcome from changing. A monotonic,
    instance-lifetime count, shaped like
    {!Riptide_batch_commit.Batch_commit.authorization_denials}: the useful reading is a delta
    around a call of interest.

    Exists so a test can prove the mechanism FIRED rather than merely that the outcome looked
    right -- "no money moved" is also what you would see if the guest had simply declined a second
    time for its own reasons, which would demonstrate nothing. A nonzero delta here is positive
    evidence that the guest genuinely decided differently and was genuinely overridden. *)

val repeat_dispatches : t -> int
(** [repeat_dispatches t] is how many decisions have arrived for a [request_id] that already had
    one, agreeing or not -- so [repeat_dispatches t - prevented_flips t] is how many were simple,
    harmless re-dispatches that happened to decide the same way. Same monotonic,
    instance-lifetime shape as {!prevented_flips}. *)

val materialize_sink :
  t ->
  read_balance:(merge_key:string -> int64 option) ->
  write_balance:(merge_key:string -> int64 -> unit) ->
  store_request:(Riptide.Value.value -> unit) ->
  Riptide_batch_commit.Batch_commit.materialize_sink
(** [materialize_sink t ~read_balance ~write_balance ~store_request] is the
    {!Riptide_batch_commit.Batch_commit.materialize_sink} that maintains this ledger's account
    balances -- wrap it with {!Riptide_module.Reactor.wrap_materialize_sink} and pass the result as
    [~materialize] to every {!Riptide_batch_commit.Batch_commit.propose} call for this ledger.

    Its [write ~merge_key payload] does one of three things:
    - [merge_key = ]{!Schema.requests_merge_key}: hands [payload] to [store_request] verbatim. A
      request is stored as-is, not accumulated; re-storing identical content on a replay is
      harmless.
    - [merge_key] is an {!Schema.account_merge_key}: decodes [payload] as a
      {!Schema.transfer_leg} and, unless this exact leg has already been applied, reads that
      account's current balance via [read_balance], adds {!balance_delta}, and writes the new
      ABSOLUTE total back via [write_balance]. [read_balance] returning [None] means "no value
      yet", i.e. balance 0 -- an account implicitly exists the first time it is referenced, per
      the design spec's own focused-core scope.
    - anything else: nothing at all, matching {!Authorize.authorize}'s own "this module has no
      opinion on any other write shape" framing.

    A payload at an account key that does not decode as a leg, or whose own [this_account]
    disagrees with the account [merge_key] names, is skipped silently rather than raised on.
    Neither can occur for a write that went through {!Authorize.authorize} -- which is every write
    that can reach a sink at all -- so this is defence in depth, not a reachable path, and a sink
    is the wrong place to raise from: it runs inside
    {!Riptide_batch_commit.Batch_commit.propose}'s own commit path, after the commit is already
    durable.

    {b Why the already-applied check is necessary at all, and what it is keyed on.}
    {!Riptide_batch_commit.Batch_commit.propose}'s materialize step runs on EVERY call for a key,
    not only the one that performed the durable commit, and re-hands the same committed leg
    payloads to this sink each time. A read-add-write accumulator is NOT idempotent under that
    replay -- it would apply the delta twice -- which is why the guard exists. (Note that
    [batch_commit.mli] itself used to claim re-materializing was a no-op "because the underlying
    join is idempotent"; that is true of a lattice join and false of any accumulating sink like
    this one. The claim has since been corrected there, at the points of use.)

    The key is the full tuple [(transfer_id, role, actor, this_account, other_account, amount)] --
    i.e. the leg's entire content, including the author that {!Authorize.authorize} guarantees is
    genuine. It was previously only [(transfer_id, this_account, role)], which silently DESTROYED
    MONEY (final whole-branch review, finding I4): a test harness's account-seeding convention
    builds its synthetic leg with [transfer_id = 0L], so a real client transfer carrying
    [request_id = 0L] -- an entirely ordinary identifier, not a reserved one -- shared a key with
    the seed leg of whichever account it credited, and the credit was skipped as a duplicate. The
    log stayed correct while the balances stopped conserving value.

    {b Known, disclosed residual gap: two genuinely distinct legs with byte-identical content are
    indistinguishable here.} The honest identity for "this committed write has already been
    applied" is the [(idempotency_key, position)] of the write within its batch, and a
    {!Riptide_batch_commit.Batch_commit.materialize_sink}'s [write] callback is handed neither --
    only [~merge_key] and the payload. Full-content keying is therefore the most specific identity
    this interface makes available, and it is exact for every request-originated leg (both carry
    the request's own [request_id] as [transfer_id], unique per transfer by
    {!Schema.transfer_request}'s own contract). What it cannot distinguish is two separately
    committed legs that agree on all six fields -- which, for a caller proposing legs outside the
    request flow (the seeding convention again), means such a caller must vary something per leg
    rather than proposing the same content twice and expecting both to land. Closing this properly
    needs the sink to receive its write's own batch identity, which is a Layer 0 signature change
    and so task-master Task 7's call, not this module's.

    {b Known, disclosed residual gap: no overflow guard on balance arithmetic} (final whole-branch
    review, finding M6, where the ruling was explicitly to document rather than code this). The
    [Int64.add] of a balance and a delta WRAPS on overflow, silently, like all of OCaml's [Int64]
    arithmetic -- so a balance driven past [Int64.max_int] (or below [Int64.min_int]) becomes
    nonsense rather than raising. At the amounts this focused-core scope operates at this is
    unreachable in practice, and a real guard is a genuinely larger piece of work than a
    proving-ground module warrants: it is not one check in one place but a decision about what the
    ledger DOES on overflow -- reject the transfer at {!Authorize.authorize} (needing a balance it
    structurally cannot see), decline it in the guest (needing 128-bit or checked arithmetic
    hand-written in WAT), or fail the materialization (leaving the log and balances disagreeing,
    which is worse than either). Named here as an accepted limitation of this scope rather than
    left for a reader to discover. *)

val read_for_guest :
  read_request:(unit -> Schema.transfer_request option) ->
  read_balance:(merge_key:string -> int64 option) ->
  merge_key:string ->
  bytes option
(** [read_for_guest ~read_request ~read_balance ~merge_key] is the host side of the guest's
    [read_materialized] host function -- wire it as {!Riptide_module.Reactor.subscribe}'s [~read].
    It is the one place {!Wire}'s read-side convention is implemented:
    {!Schema.requests_merge_key} answers with {!Wire.encode_request} of the current request,
    an {!Schema.account_merge_key} with {!Wire.encode_balance} of that account's balance, and
    every other key with [None].

    [None] -- from either supplied closure, or from an unrecognised [merge_key] -- reaches the
    guest as a ZERO-LENGTH read, which is this convention's own "no value yet" signal (matching
    [counter.wat]'s precedent). A guest must therefore treat a zero-length balance read as
    balance 0, and this is exactly what [ledger.wat] does. *)
