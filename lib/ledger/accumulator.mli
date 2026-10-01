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
(** One ledger module instance's own host-side state, which is now {b nothing but the two
    observability counters} {!prevented_flips} and {!repeat_dispatches} (Task 7, the Layer 0/Layer 2
    boundary revision). It holds no decision table and no already-applied-legs table; both were
    deleted outright rather than persisted in parallel, and neither this type nor any value of it is
    load-bearing for correctness any more.

    {b What this type USED to be, stated because the change is the entire point of Task 7 and
    because a reader coming from the previous interface will expect otherwise.} It carried two
    in-memory [Hashtbl.t]s -- the first-decision-wins table and the already-applied-legs table --
    and neither survived a process restart. The consequence was worse than a stale decision: a
    restart followed by any catch-up materialization silently DOUBLED every account balance in the
    ledger. Live-reproduced (1500 units across two accounts became 3000) and pinned as
    then-accepted behaviour by a test that deliberately asserted the doubling. That test is gone,
    replaced in the same slot by
    [test_restart_with_durable_watermark_leaves_balances_correct] in
    [test/test_ledger_end_to_end.ml], which runs the identical restart-plus-catch-up scenario and
    asserts the balances come out right.

    {b What replaced each table, and what each replacement asks of a caller:}

    - The decision table became a query against the REPLICATED LOG. A decision -- accepted or
      declined -- is now committed as its own write ({!Legs.decision_write}), atomically with the
      legs it authorises, under the transfer's own {!Schema.transfer_idempotency_key}. "Has this
      request already been decided, and how?" is answered by
      {!Riptide_batch_commit.Batch_commit.committed_writes_for}, threaded in as this module's
      {!committed} parameter. Two processes cannot disagree about it, and a restart cannot lose it
      {b for as long as the log entry carrying it is still in the WAL} -- which, for a DECLINE, is a
      real qualifier rather than a formality (Task 4's own review, Minor): a decline's batch is that
      one decision write alone, it carries [merge_key = None], and
      {!Riptide_batch_commit.Batch_commit.write_at_op_number_has_merge_key} therefore reports its
      entry as freely evictable by {!Riptide_storage.File_storage}'s bounded ring WAL. Evicting it
      loses the decline record and makes that request re-decidable. See {!Legs.decision_write}'s own
      doc comment, which discloses this in full, including why an ACCEPT does not have the same
      exposure (its batch shares an entry with two [merge_key]-carrying legs). Still strictly better
      than the in-memory table this replaced, which lost EVERY decision, accepted and declined alike,
      on every restart -- but not the unconditional "a restart cannot lose it" this paragraph used to
      claim.
    - The already-applied-legs table became
      {!Riptide_batch_commit.Batch_commit.deduplicate}: a durable, per-[(idempotency_key, position)]
      record that a committed write has already been handed to a sink, composed around a sink as a
      wrapper. {b This is a real obligation on whoever wires this module's sink up}, not an internal
      detail -- {!materialize_sink} below is a plain read-add-write accumulator with no dedup of its
      own, so a caller that passes it UNWRAPPED (to
      {!Riptide_batch_commit.Batch_commit.propose}'s [?materialize], or to a
      {!Riptide_batch_commit.Batch_commit.materialize_up_to} walk) re-applies every replayed leg and
      reintroduces exactly the doubling described above. See {!materialize_sink}.

    {b HOW THAT WRAPPER MUST BE COMPOSED, which is correctness-critical and not a matter of taste}
    (Task 4's own review, Critical 1 -- live-reproduced on two DST seeds). The watermark wraps ONLY
    this module's own accumulator sink, and {!Riptide_module.Reactor.wrap_materialize_sink} sits
    strictly OUTSIDE it:
    {[
      Reactor.wrap_materialize_sink reactor
        (Batch_commit.deduplicate ~watermark_store
           (Accumulator.materialize_sink ~read_balance ~write_balance ~store_request))
    ]}
    The reactor wrapper's own [write] runs its inner sink and THEN dispatches every subscribed guest.
    {!Riptide_batch_commit.Batch_commit.deduplicate} skips the sink it wraps ENTIRELY for an
    already-applied write -- so with the two nested the other way round, re-materializing an
    already-materialized {!Schema.requests_merge_key} write stops re-dispatching the guest. That is
    not a harmless optimization: {!handle_guest_decision}'s "re-propose an already-accepted request's
    batch" path is reached ONLY by a fresh dispatch, and nothing else in this system ever re-proposes
    a batch a VSR view change discarded before it committed, so suppressing re-dispatch makes such a
    transfer PERMANENTLY unrecoverable -- a liveness softlock on a cluster with nothing wrong with it
    (no money moves wrongly; it simply never completes).

    {b This paragraph previously documented that softlock as correct behaviour}, saying
    re-materializing an already-materialized request "no longer re-reaches the guest at all... the
    watermark working as designed rather than a gap". It was neither by design nor acceptable. With
    the composition above, materialization of a given committed write still happens at most once ever
    -- that is the exactly-once property this plan exists to deliver -- while guest dispatch fires on
    every materialize call unconditionally. Both at once is the point; they are not in tension once the
    gate is composed at the right layer. *)

val create : unit -> t

type committed =
  idempotency_key:string -> Riptide_batch_commit.Batch_commit.write list option
(** The committed-log query this module asks instead of keeping its own decision table -- wire it to
    [fun ~idempotency_key -> Riptide_batch_commit.Batch_commit.committed_writes_for replica
    ~idempotency_key] against the same replica the deployment's own
    {!Riptide_batch_commit.Batch_commit.t} wraps.

    A closure rather than a {!Riptide_batch_commit.Batch_commit.t} argument, for the same reason
    everything else here is one: this library stays free of any opinion about how a deployment gets
    at its own committed log, and a caller that routes proposals through a re-derived current primary
    (as this module's own DST harness does, since a primary can move mid-run) can answer this from
    whichever replica it is actually talking to. *)

val balance_delta : Schema.transfer_leg -> int64
(** [balance_delta leg] is the SIGNED amount [leg] moves its own {!Schema.transfer_leg.this_account}
    by: [-amount] for {!Schema.Debit}, [+amount] for {!Schema.Credit}. The single place that
    derivation lives -- a leg stores a positive magnitude and a role, never a signed amount (see
    {!Schema.transfer_leg}). *)

val decision : committed:committed -> request_id:int64 -> bool option
(** [decision ~committed ~request_id] is [Some accepted] if a decision for [request_id] has
    COMMITTED on the log [committed] reads, [None] if it has not.

    {b Takes no {!t}, deliberately} (Task 7, the Layer 0/Layer 2 boundary revision -- it used to take
    one): a decision is not per-instance state any more, and a signature that implied otherwise would
    be the single most misleading thing left in this interface. Any two instances, in any two
    processes, reading the same replicated log give the same answer here; a fresh instance after a
    restart gives the same answer the retired one did.

    [None] covers three operationally distinct situations, and a caller must not read it as
    "declined": nothing was ever decided; a decision was decided but has not COMMITTED on this
    replica yet (replication lag, or a batch a view change discarded before quorum); or a batch
    exists under this request's own idempotency key but carries no decision record at all, which
    nothing in this module can produce and {!Authorize.authorize_batch} does not itself forbid for a
    batch carrying no legs either.

    {b Once [Some _], it never changes} -- the log's own first-wins-per-key rule guarantees that, and
    that part really is stronger than the in-memory table this replaced (which was immutable only for
    one process's lifetime, and which a restart lost entirely).

    {b But the committed-log scheme is NOT uniformly "strictly stronger" than that table, and this
    doc claimed it was} (Task 4's own review, Important 2). There is one window where it is strictly
    WEAKER: between a decision being APPENDED by {!handle_guest_decision}'s [~propose] and that batch
    actually COMMITTING. The in-memory table recorded a decision the instant the guest produced it, so
    a second dispatch in that window saw it and could not change it. This function cannot -- it reads
    the committed log, so it answers [None] for an appended-but-uncommitted decision, and a second
    dispatch in that window therefore takes the "never decided" branch and proposes its own decision
    under the same key. Normally harmless: {!Riptide_batch_commit.Batch_commit.propose}'s own "already
    in my log" skip makes the second proposal a no-op while the first is still present. {b It stops
    being harmless if a view change discards the first batch before quorum} -- the second decision is
    then free to become the record, so a DECLINE genuinely can end up recorded as an ACCEPT (or vice
    versa). That outcome was unreachable with the in-memory table and is reachable now. It is bounded:
    whichever decision commits is still a real decision the guest really made for this request, about
    this request's own amount and accounts (so no transfer is fabricated), it is final once committed,
    and the window is exactly "appended but not yet committed" -- nil on a solo replica, where
    {!Riptide_batch_commit.Batch_commit.propose} commits synchronously. Closing it would mean a
    decision that is durable before it is committed, which is a Layer 0 question (a pre-commit
    intent record) rather than something this module can answer. Named here as a real, disclosed
    trade of the Task 7 design rather than left for a reader to infer from an overclaim. *)

val handle_guest_decision :
  t ->
  actor:Riptide.Envelope.actor_id ->
  committed:committed ->
  propose:(idempotency_key:string -> Riptide_batch_commit.Batch_commit.write list -> unit) ->
  bytes ->
  (unit, string) result
(** [handle_guest_decision t ~actor ~committed ~propose decision_bytes] is the host side of the
    guest's [propose_write] host function -- wire this as {!Riptide_module.Reactor.subscribe}'s
    [~propose], with [propose] itself calling
    {!Riptide_batch_commit.Batch_commit.propose} against whatever handle and [~materialize] sink
    that deployment uses. [Error] (relayed to the guest as a nonzero status byte) if
    [decision_bytes] is not a well-formed {!Wire.decision_bytes}-byte decision payload; [Ok ()]
    otherwise, whatever the decision turns out to be -- a declined transfer is a normal outcome,
    not an error.

    {b The closure wired to [~propose] should check
    {!Riptide_batch_commit.Batch_commit.is_primary} immediately before every
    {!Riptide_batch_commit.Batch_commit.propose} call} (Task 7, design spec Decision 5), or, more
    simply, the caller's own [~propose] closure should check it before calling this function at all
    and report [Error "not primary, retry"] without dispatching -- which is what this module's own
    test harness does. {b Why checking once, up front, rather than per outcome is correct} (Task 4's
    own review, Minor -- this used to claim "EVERY outcome of this function proposes something", which
    is false: the already-decided-DECLINED outcome proposes nothing by design, and a decode error
    returns [Error] before reaching any outcome at all): the outcomes that DO propose -- a first
    decision, accept or decline, and the re-proposal of an already-accepted batch -- are the ones a
    silent non-primary no-op would actually lose, and they are not distinguishable from the
    propose-nothing outcomes until after the guest's bytes have been decoded and the committed log
    consulted. Checking up front costs one predicate and covers every outcome that has something to
    lose; checking per outcome would mean re-deriving the same answer in three places for no
    additional guarantee, since nothing between the two points can make a primary stop being one in a
    way an earlier check would have caught (see {!Riptide_batch_commit.Batch_commit.is_primary}'s own
    disclosed residual non-atomicity). Without the check at all, a non-primary (or
    non-[Normal]) replica turns {!Riptide_batch_commit.Batch_commit.propose} into a silent no-op and
    the guest's decision is lost with no trace and no way to tell that from success.

    The decode-and-construct half is {!Legs.decision_of_bytes} -- called here, and the only place
    a guest's raw bytes are ever decoded in this module's host half, which is what makes that
    function's "this is the guest-facing trust boundary" claim (and the fuzz test standing behind
    it) true of the real production path rather than of a test-only one. It was NOT called here
    through fix round 1, which is a defect round 2 closed; see that function's own doc comment.

    {b The first decision ever COMMITTED for a [request_id] is final, and that is the whole point
    of this function} (final whole-branch review, finding C1 -- a Critical). Concretely:

    - {b Never decided before} ([decision ~committed ~request_id = None]). The decision is COMMITTED,
      as the whole batch {!Legs.batch_of_decision} builds, under
      {!Schema.transfer_idempotency_key} of the request's own [request_id]: a durable decision record
      plus, if ACCEPTED, the two legs {!Legs.legs_of_request} builds -- one atomic unit. {b A DECLINE
      proposes too}, and that is the change that let the in-memory decision table be deleted: a
      decline used to propose nothing at all, so the only trace of it was that table, so a restart
      lost it.
    - {b Already decided DECLINED.} Nothing further is proposed, ever, no matter what this dispatch
      decided. This is the case the bug lived in: the guest's decline previously left no trace
      anywhere durable, so any later re-materialization of the same already-committed
      "ledger.requests" write re-dispatched the guest against a CURRENT balance that may since have
      grown, it legitimately decided ACCEPT, and the host committed a transfer that no client ever
      asked for twice.
    - {b Already decided ACCEPTED.} The batch is re-proposed, rebuilt from the ORIGINALLY COMMITTED
      request (read back out of the log's own decision record) rather than from this dispatch's own
      bytes, under the same idempotency key as before.

    {b Why an already-accepted request re-proposes rather than doing nothing}, since "ignore any
    later dispatch" would be the simpler rule: a batch that has been appended but not yet committed
    is exactly what a VSR view change is entitled to discard, and nothing else in this system ever
    re-proposes it -- so re-triggering the dispatch that produced it is the only recovery path there
    is, and it is a real one, exercised for real by this module's own DST test. Re-proposing is safe
    on both counts that matter: under the same idempotency key
    {!Riptide_batch_commit.Batch_commit.propose} skips re-appending a batch already in the log, and
    its own durable watermark will not re-hand a write it has already handed to the sink. Taking the
    request from the log's own record makes this strictly STRONGER than merely pinning the
    accept/decline bit, not a weakening of it: a later dispatch can change neither the decision nor
    the amount or accounts the transfer moves. (Note that this branch is only reachable at all while
    the decision has COMMITTED but its sibling legs have not yet been materialized on this replica --
    if [committed] returns [None] because the whole batch was discarded pre-quorum, the first branch
    above re-proposes it from scratch instead, which is equally correct.)

    [actor] is the identity the decision record and both legs are proposed under, and is recorded
    inside each leg's own payload as well (see {!Schema.transfer_leg}'s [actor] field). Each batch's
    [causation]/[correlation] are derived deterministically from its own idempotency key, so a
    re-proposal is byte-identical to the original rather than merely equivalent. *)

val prevented_flips : t -> int
(** [prevented_flips t] is how many times a dispatch has produced a decision for a [request_id]
    that already had one COMMITTED AND DISAGREED with it -- i.e. how many times the
    first-decision-wins rule above has actually prevented a request's outcome from changing. A
    monotonic, instance-lifetime count, shaped like
    {!Riptide_batch_commit.Batch_commit.authorization_denials}: the useful reading is a delta
    around a call of interest.

    Exists so a test can prove the mechanism FIRED rather than merely that the outcome looked
    right -- "no money moved" is also what you would see if the guest had simply declined a second
    time for its own reasons, which would demonstrate nothing. A nonzero delta here is positive
    evidence that the guest genuinely decided differently and was genuinely overridden.

    {b Instance-lifetime, and therefore 0 on a fresh instance after a restart} -- unlike the
    decisions themselves, which are durable. That is the honest shape for an observability counter
    and is itself useful: a fresh instance whose [prevented_flips] rises is positive evidence that it
    read a pre-restart decision out of the log rather than deciding afresh. *)

val repeat_dispatches : t -> int
(** [repeat_dispatches t] is how many decisions have arrived for a [request_id] that already had one
    COMMITTED, agreeing or not -- so [repeat_dispatches t - prevented_flips t] is how many were
    simple, harmless re-dispatches that happened to decide the same way. Same monotonic,
    instance-lifetime shape as {!prevented_flips}. *)

val materialize_sink :
  read_balance:(merge_key:string -> int64 option) ->
  write_balance:(merge_key:string -> int64 -> unit) ->
  store_request:(Riptide.Value.value -> unit) ->
  Riptide_batch_commit.Batch_commit.materialize_sink
(** [materialize_sink ~read_balance ~write_balance ~store_request] is the
    {!Riptide_batch_commit.Batch_commit.materialize_sink} that maintains this ledger's account
    balances -- wrap it with {!Riptide_module.Reactor.wrap_materialize_sink} and pass the result as
    [~materialize] to every {!Riptide_batch_commit.Batch_commit.propose} call for this ledger.

    {b Takes no {!t}} (Task 7, the Layer 0/Layer 2 boundary revision -- it used to): with the
    already-applied-legs table deleted, this sink holds no state at all. One sink is valid for a
    deployment's whole lifetime, restart included, and nothing has to be rebuilt alongside a fresh
    {!t}.

    Its [write ~merge_key ... payload] does one of three things:
    - [merge_key = ]{!Schema.requests_merge_key}: hands [payload] to [store_request] verbatim. A
      request is stored as-is, not accumulated; re-storing identical content on a replay is
      harmless.
    - [merge_key] is an {!Schema.account_merge_key}: decodes [payload] as a
      {!Schema.transfer_leg}, reads that account's current balance via [read_balance], adds
      {!balance_delta}, and writes the new ABSOLUTE total back via [write_balance]. [read_balance]
      returning [None] means "no value yet", i.e. balance 0 -- an account implicitly exists the
      first time it is referenced, per the design spec's own focused-core scope.
    - anything else -- including a {!Legs.decision_write}, which carries no [merge_key] and so never
      reaches a sink at all: nothing, matching {!Authorize.authorize}'s own "this module has no
      opinion on any other write shape" framing.

    A payload at an account key that does not decode as a leg, or whose own [this_account]
    disagrees with the account [merge_key] names, is skipped silently rather than raised on.
    Neither can occur for a write that went through {!Authorize.authorize} -- which is every write
    that can reach a sink at all -- so this is defence in depth, not a reachable path, and a sink
    is the wrong place to raise from: it runs inside
    {!Riptide_batch_commit.Batch_commit.propose}'s own commit path, after the commit is already
    durable.

    {b THE ONE REAL OBLIGATION THIS PLACES ON A CALLER: this sink is NOT idempotent, and it carries
    no already-applied check of its own, so every path that drives it MUST drive it through the
    durable watermark.} Concretely: wrap it, once, in
    {!Riptide_batch_commit.Batch_commit.deduplicate} with a real [~watermark_store], and pass THAT
    everywhere this sink would otherwise go -- as {!Riptide_batch_commit.Batch_commit.propose}'s
    [?materialize] and as every {!Riptide_batch_commit.Batch_commit.materialize_up_to} catch-up walk's
    [~materialize]. {b And wrap it INSIDE
    {!Riptide_module.Reactor.wrap_materialize_sink}, never outside} -- see {!t}'s own doc comment above
    for why that ordering is correctness-critical rather than stylistic, and for the liveness softlock
    that getting it backwards produced.

    Why it is necessary at all: {!Riptide_batch_commit.Batch_commit.propose}'s materialize step runs
    on EVERY call for a key, not only the one that performed the durable commit, and re-hands the
    same committed leg payloads to this sink each time; {!Riptide_batch_commit.Batch_commit.materialize_up_to}
    replays the whole log by design; and a restarting node is documented to perform exactly such a
    walk. A read-add-write accumulator applies its delta again every time, so a caller that omits
    the watermark moves money no client asked to move. (Note that [batch_commit.mli] itself used to
    claim re-materializing was a no-op "because the underlying join is idempotent"; that is true of a
    lattice join and false of any accumulating sink like this one. The claim has since been corrected
    there, at the points of use.)

    {b Why the watermark, and not a dedup key computed in here, is the right mechanism} -- stated
    because this interface carried two successive attempts at the latter, and both were defects. The
    honest identity for "this committed write has already been applied" is the
    [(idempotency_key, position)] of the write within its batch. Before Task 7 a sink was handed
    NEITHER, so this one deduped on the leg's content instead: first on
    [(transfer_id, this_account, role)], which silently DESTROYED MONEY (final whole-branch review,
    finding I4 -- a test harness's account-seeding convention built its synthetic leg with
    [transfer_id = 0L], so a real client transfer carrying [request_id = 0L], an entirely ordinary
    identifier, shared a key with the seed leg of whichever account it credited and had its credit
    skipped as a duplicate); then on the leg's full six-field content, which was exact for
    request-originated legs but still could not distinguish two genuinely distinct writes with
    byte-identical content. {!Riptide_batch_commit.Batch_commit.materialize_sink}'s [write] now
    receives the real identity, and {!Riptide_batch_commit.Batch_commit} uses it to make the dedup
    durable -- which no table in this process could be -- so both the collision and the restart
    doubling are closed by the same change, structurally rather than by a better guess at a key.

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
