(** A single VSR replica's state and message handling — ALL ELEVEN of `spec/tla/VSR.tla`'s actions:
    [ReceiveClientRequest], [ReceivePrepareMsg], [ReceivePrepareOkMsg], [PrimaryExecuteOp]
    (VSR.tla:91-155), [TimerSendSVC], [ReceiveHigherSVC], [ReceiveMatchingSVC], [SendDVC],
    [ReceiveDVC], [SendSV], and [ReceiveSV] (VSR.tla:161-305), against a real, mutable
    [status]/[view_number] rather than a fixed primary.

    {b Scope}: the normal-case actions are implemented against the GENERAL form of their guards
    ([IsNormalPrimary(r) == status[r] = "Normal" /\ Primary(View(r)) = r] and
    [IsNormalBackup(r) == status[r] = "Normal" /\ Primary(View(r)) # r], VSR.tla:48-49), and the
    view-change half is now complete end to end: a replica moves itself into [View_change] (on its
    own timeout, or on hearing of a higher view), collects corroborating [StartViewChange]s, sends
    its own [DoViewChange] to the new primary, accumulates other replicas' [DoViewChange]s, and —
    if it is the new primary — selects the surviving log, starts the new view, and broadcasts
    [StartView]; a replica receiving that [StartView] adopts the new view and returns to [Normal].
    {!check_timeout} implements [TimerSendSVC]; {!handle_message}'s [Start_view_change] dispatch
    implements [ReceiveHigherSVC]/[ReceiveMatchingSVC], its [Do_view_change] dispatch implements
    [ReceiveDVC], and its [Start_view] dispatch implements [ReceiveSV]. [SendDVC] and [SendSV] have
    no separate entry points of their own — both are derived actions driven from whichever handler
    changes what their guards read (see {!handle_message}'s own doc comment).

    {b Storage-fault-aware recovery is now in scope too} — the remaining actions of
    `spec/tla/VSR.tla`'s own extension: the multi-step, interruptible view-change completion
    ([HasDvcQuorum]/[NackCount]/[ProvenAbsent]/[EntrySources]/[CanFill]/[FillValue]/
    [ValidCompletion]/[CanComplete]/[CompletionPoint], VSR.tla:403-516, driven from
    {!handle_message}'s [Do_view_change] dispatch), the forfeit escape ([ForfeitViewChange],
    VSR.tla:542-556, driven from {!check_timeout}), and crash/restart with a durable/volatile
    split ([CrashRestart], VSR.tla:671-690, which is {!restart}). All of it reads and writes
    through a real {!Riptide_storage.Storage_intf.S} backend supplied at construction — see
    {!storage}.

    {b Still out of scope}, as for `spec/tla/VSR.tla` itself (see `spec/tla/README.md`):
    state-transfer (so a replica that restarts with an unreadable slot below its own op-number
    waits for a [StartView] to repair it rather than fetching the missing entry from a peer),
    reconfiguration, the client table, and COMMIT messages. Two disclosed, liveness-only
    simplifications are inherited
    directly from the spec: no [PrepareOk] re-send on [StartView], and only a higher-view
    [StartViewChange] (never a higher-view [DoViewChange]) makes a replica adopt a higher view.

    {b View number}: {!handle_message} enforces VSR.tla's own [m.view = View(r)] guard by
    dropping any [Prepare]/[Prepare_ok] (the two normal-case types that carry a [view] field)
    whose [view] isn't exactly {!view_number}'s current value. The view-change message types name
    their own field [v], not [view], and are matched against {!view_number} by their own actions'
    guards instead (see {!check_timeout} and {!handle_message}'s own doc comments).

    {b Replica identity}: replica ids are [1..replica_count], matching VSR.tla's own
    [replicas == 1..ReplicaCount] (VSR.tla:15). There is no stored, configured "primary" field
    any more — {!create}'s caller no longer supplies one. Which replica id is primary is now
    ALWAYS the pure function [Primary(v) == 1 + ((v-1) % ReplicaCount)] (VSR.tla:18) applied to
    {!view_number}'s current value — see {!primary} below.

    {b TLA+'s [%] is Euclidean (floored) modulo, not OCaml's truncating [mod]} — [(0-1) %
    ReplicaCount] is [ReplicaCount - 1], so [Primary(0)] is [ReplicaCount], NOT [1]. Verified
    directly with TLC 2.19 against VSR.tla:18's own formula at [ReplicaCount = 3]: [Primary(0) =
    3], [Primary(1) = 1], [Primary(2) = 2] — re-confirmed computationally (a throwaway [ocaml]
    script, not by mental arithmetic) against {!primary}'s own normalized-modulo implementation
    before it was written into [replica.ml], giving the same three values. Since
    [view_number] starts at [0] at {!create} (VSR.tla's own [Init], VSR.tla:79), a replica
    constructed with [replica_count = 3] and left untouched starts with replica [3], NOT replica
    [1], as its primary — do not assume replica [1] is ever the "natural" starting primary; it
    only becomes primary once [view_number] itself reaches a value [v] with [Primary(v) = 1] (any
    [v ≡ 1 (mod replica_count)], e.g. [v = 1]).

    {b [dest] and message delivery}: {!Riptide_vsr.Message.t} deliberately omits the TLA+ spec's
    own [dest] field (see [message.mli]) because the transport layer's own destination argument
    already carries it. Consequently VSR.tla's [ReceivableMsg(m, type, r)]'s own [m.dest = r]
    conjunct (VSR.tla:68) needs no separate check here: by construction, a message only ever
    reaches a replica's {!handle_message} by way of that replica's own transport handle, which
    is exactly what "dest = r" meant in the TLA+ message-bag model. *)

type status = Normal | View_change
(** VSR.tla's own [rep_status[r]] (VSR.tla:29), whose two values are the string literals
    ["Normal"]/["ViewChange"] there — renamed here only for OCaml's own constructor-casing
    convention, no semantic change. *)

type t
(** One replica's mutable state: its log, op-number, commit-number, view-change
    status/view-number/last-normal-view, (primary-only) per-peer acknowledgment high-water marks,
    and — since the storage-fault-tolerant-recovery work — the durable {!storage} backend all of
    the above is written through. *)

type storage
(** A {!Riptide_storage.Storage_intf.S} backend, with its own [type t] already erased — build one
    with {!storage_of_module} (or {!volatile_storage}) and hand it to {!create}/{!restart}.

    Erasing the backend's type at construction is what keeps {!t} monomorphic. The alternative,
    storing the module and its value inside {!t}, would make it [('backend) Replica.t] and infect
    every signature in this module, {!Riptide_batch_commit}, and every test — for no behavioural
    difference, since nothing here ever needs to recover the backend's concrete type. This mirrors
    how {!create} already takes its transport as a value ([send]) rather than as a functor
    parameter. *)

val storage_of_module : (module Riptide_storage.Storage_intf.S with type t = 'a) -> 'a -> storage
(** [storage_of_module (module B) backend] packages an already-constructed backend value. Nothing
    is copied and no state is read: the returned {!storage} is a view of [backend], so two
    replicas given views of the SAME backend share one durable log (which is what makes
    {!restart} able to recover a replica's own state, and what makes handing one backend to two
    different replicas a bug). *)

val volatile_storage : unit -> storage
(** A fresh {!Riptide_storage.Memory_storage} backend, packaged.

    {b Not durable across a process exit} — it is in-process memory. It is the right choice for
    tests that never exercise a restart, and for any caller that wants VSR's protocol behaviour
    without real durability; it is the wrong choice for anything that must survive a crash, which
    is {!Riptide_storage.File_storage}'s job. Named [volatile_] rather than [memory_] for exactly
    that reason: the property that matters at a call site is what is lost, not where it is kept. *)

val create :
  ?on_commit_advanced:(old_commit:int -> new_commit:int -> unit) ->
  my_id:int ->
  replica_count:int ->
  svc_limit:int ->
  send:(to_:int -> string -> unit) ->
  storage:storage ->
  unit ->
  t
(** [create ~my_id ~replica_count ~svc_limit ~send ~storage ()] is a fresh replica matching VSR.tla's [Init]
    (VSR.tla:71-84) restricted to this replica [my_id]: empty log, [op_number = 0],
    [commit_number = 0], [status = Normal], [view_number = 0], [last_normal_view = 0],
    [recv_svc]/[recv_dvc] empty, [sent_dvc = false], [svc_count = 0], no peer acknowledgments
    recorded yet.

    {b The trailing [()] is required by OCaml's own optional-argument erasure rule}, not
    decoration: an optional argument is only erased when the function is applied to a
    {i non-labelled} argument appearing after it. Every other parameter here is labelled, so
    without a final [unit] a call that omits [?on_commit_advanced] would have type
    [?on_commit_advanced:... -> t] rather than [t] and fail to typecheck (verified against the
    real compiler — warning 16, [unerasable-optional-argument]). {!restart} carries the same [()]
    for the same reason.

    {b There is no [primary_id] parameter any more} — an earlier, normal-case-only plan's fixed
    primary is gone; which replica id is primary is now always computed from {!view_number} via
    {!primary} (see this module's own top-level scope note). [svc_limit] is VSR.tla's own
    [StartViewOnTimerLimit] (VSR.tla:13) — stored on [t], validated at {!create} time (see below),
    and read by {!check_timeout} (this task's own first reader) to bound {!check_timeout}'s own
    action, per that function's own doc comment — [svc_limit] is the parameter that structurally
    replaced the removed [primary_id] in this signature, and its own range needs the same kind of
    cheap sanity check [primary_id] used to get.

    Raises [Invalid_argument] if [replica_count < 1]; if [replica_count] is even (VSR.tla:140's
    own comment assumes [2f+1 = ReplicaCount], i.e. an odd count — [spec/tla/VSR.cfg] never
    instantiates an even one, and this module doesn't either); if [my_id] falls outside
    [1, replica_count] (VSR.tla's own [replicas == 1..ReplicaCount], VSR.tla:15); or if
    [svc_limit < 1] — VSR.tla:163's own [TimerSendSVC] guard is [aux_svc_count[r] <
    StartViewOnTimerLimit], and [aux_svc_count[r]] starts at [0] ([Init]) and is never negative, so
    a non-positive [svc_limit] would make that guard permanently unsatisfiable, silently disabling
    view-change from ever starting on this replica — a failure mode indistinguishable from "no view
    change happened because nothing triggered one" without this check. These are cheap, deliberate
    sanity checks on {!create}'s own arguments, not a defense against adversarial network input
    (that's {!handle_message}'s job — see its own doc comment below); a [replica_count = 1] cluster
    is accepted (it is odd and [>= 1]) and behaves per VSR.tla's own degenerate [f = 0] case — see
    {!propose}'s own doc comment for what that implies.

    [send] is a closure over some transport handle's own [send : t -> to_:int -> string -> unit]
    (see {!Riptide_transport.Transport_intf.S.send}) with the handle itself and [~to_]'s type
    already applied down to just [to_:int -> string -> unit] — deliberately NOT a direct
    dependency on [Transport_intf.S] or [lib/transport] at all (this library's own [dune] has no
    such dependency; see this plan's own design notes), so this module stays usable against any
    future transport implementation that can produce a closure of this shape. [send] is called
    synchronously, inline, from within {!propose} and {!handle_message} — never queued or
    deferred — so a caller supplying a closure that itself blocks will block the caller of
    {!propose}/{!handle_message} too.

    [storage] is the durable backend this replica writes its WAL and superblock through — see
    {!storage_of_module}/{!volatile_storage}. {b It must be empty}: [create] raises
    [Invalid_argument] if the backend already holds a WAL entry or a superblock, because a
    non-empty backend means a previous life whose durable [view_number]/[last_normal_view] this
    constructor would silently discard — and those two surviving a crash is the whole basis of
    the recovery mechanism (VSR.tla's Decision 4). {!restart} is the constructor for that case.

    [?on_commit_advanced], if supplied, is a progress hook invoked {b synchronously and inline}
    (from within whichever {!propose} or {!handle_message} call caused the advance, on that
    caller's own stack — never queued or deferred, exactly like [send] above, so a hook that blocks
    blocks the protocol; {!check_timeout} can never trigger it, since none of the four commit sites
    is reachable from it — it reaches [SendDVC] only, never [SendSV]) {b exactly once per genuine increase} in {!commit_number},
    with [~old_commit] the value immediately before the change and [~new_commit] the value
    immediately after. It is given plain [int]s and nothing else: {!Replica} is Layer 0 and stays
    domain-agnostic about what a consumer does with commit progress (the ring-eviction watermark is
    the first consumer). Omitting it is the zero-cost default and leaves behaviour bit-for-bit
    identical to before this parameter existed.

    {b "Exactly once per genuine increase" is enforced by [Replica], not inherited from its commit
    sites — and that distinction is real, not pedantic.} [commit_number] is assigned at four places
    in the implementation. Three of them guard on a strict increase already ([primary_execute_op]'s
    [next = commit_number + 1]; [handle_prepare]'s and {!handle_message}'s [Start_view] path's
    [if k > commit_number]). The fourth, [SendSV] (VSR.tla:508's
    [rep_commit_number' = HighestCommitNumber(r)]), is {b deliberately unconditional and can
    genuinely LOWER [commit_number]} — the new primary starts the view from the winning DVC set's
    own maximum, not from its own prior value, and [test_vsr_replica.ml]'s own
    [test_send_sv_commit_number_assignment_is_unconditional_not_monotonic] pins a real 1 {b ->} 0
    drop. A single internal writer therefore gates the callback on [new_commit > old_commit]: a
    decrease still happens to the field (no protocol behaviour is changed by this hook) but is
    {b never reported as an advance}, so a monotonic consumer such as a watermark can never be
    driven backwards. Consequently the hook is {b not} a faithful audit log of every write to
    [commit_number]; it is a report of forward progress only.

    {b Not invoked retroactively.} No callback is made during {!create}/{!restart} itself for
    commit progress the replica already knows about — in particular a {!restart} that recovers
    [commit_number = 7] from its superblock fires nothing for 1..7, and the first callback that
    replica ever makes is for its next real advance ([~old_commit = 7]). A caller that needs
    restart-time catch-up must read {!commit_number} itself right after construction and seed its
    own state from it.

    {b What replica state is settled when the hook fires — [commit_number]/[op_number]/[entries]
    always, [status]/[view_number]/[last_normal_view] NOT always.} The hook is invoked from the
    middle of the action that caused the advance, not after it returns, so a consumer that
    re-enters this replica from inside the callback does not see a uniformly post-action [t]. At
    all four commit sites, {!commit_number}, {!op_number} and {!entries} are already fully
    updated and final — reading those from inside the hook is always safe, and is the intended
    way to use it. But at the two {b view-change-related} sites the hook fires {b before} the
    view-change bookkeeping is written, and {b what those fields read is NOT the same at the two
    sites} — so they are stated separately rather than jointly:

    - [try_send_sv] ([SendSV], VSR.tla:499-516). {!status} is {b guaranteed} to read [View_change]
      here: this site is reachable only past [has_dvc_quorum], whose own first conjunct
      (VSR.tla:489) {i is} [status = View_change]. {!view_number} already holds the NEW view — the
      replica entered it before this action began, and [try_send_sv] never writes [view_number] at
      all. {!last_normal_view} still holds its OLD value.
    - [handle_start_view] ([ReceiveSV], VSR.tla:567-578). {!status} holds whatever its
      {b pre-action} value was, which is {b either [View_change] or [Normal]} — VSR.tla:567-570's
      guard is only [ReceivableMsg(m, "StartView", r) /\ m.v >= View(r)], with {b no status
      conjunct at all} (the implementation's own guard matches, deliberately). So a replica that is
      still [Normal] and has never entered a view change can receive a higher-view [Start_view] and
      advance its {!commit_number} through this site with [status = Normal] the whole time — a real,
      reachable follower-catch-up case, pinned by [test_vsr_replica.ml]'s own
      [test_on_commit_advanced_from_receive_sv_on_a_still_normal_backup], which reads {!status} from
      inside the callback and requires [Normal]. {!view_number} still holds the OLD view here, and
      {!last_normal_view} its old value.

    All of those fields are updated a few lines later in the same call, and the view change does
    complete.

    {b Nothing is durable yet when the hook fires — at any of the four sites.} The advance is an
    in-memory assignment; the [persist_superblock] that puts the new [commit_number] on disk runs
    {b after} the callback returns, at every site ([primary_execute_op] additionally batches: it can
    fire the hook several times and persist once at the end of the loop). A crash between the two
    therefore loses the advance — the replica comes back up at the {i older} [commit_number]. This
    matters for a consumer that writes its own derived state durably from inside the callback: that
    write can survive a crash the replica's own [commit_number] did not, so such a consumer must
    tolerate its watermark being {i ahead} of the restarted replica's [commit_number], not assume
    the two are in lockstep.

    {b Therefore: never gate work done inside the callback on {!status} or {!view_number} at all —
    in either direction.} Not on [status t = Normal] (a consumer that skipped an advance whenever
    [status <> Normal] would silently drop exactly the advances a {b follower learns through a view
    change}, the follower-catch-up case that is the main reason this hook exists), and equally not
    on [status t = View_change] as a way to recognise "this advance came from a view change" (per
    the split above that inference is simply false at [handle_start_view], the very site where
    follower catch-up happens). The commit advance being reported is real and final regardless of
    what those fields read. If a consumer genuinely needs post-action view state, it must do that
    work after {!propose}/{!handle_message} returns, not inside the hook. *)

val restart :
  ?on_commit_advanced:(old_commit:int -> new_commit:int -> unit) ->
  my_id:int ->
  replica_count:int ->
  svc_limit:int ->
  send:(to_:int -> string -> unit) ->
  storage:storage ->
  unit ->
  t
(** [restart ~my_id ~replica_count ~svc_limit ~send ~storage ()] is VSR.tla's [CrashRestart]
    (VSR.tla:671-690): a replica coming back up on top of storage that already holds its durable
    state. Same argument validation as {!create}, and the same [Invalid_argument] cases for
    [my_id]/[replica_count]/[svc_limit] — but no emptiness requirement, since recovering existing
    durable state is the point. An empty backend (no superblock AND an empty WAL) is accepted and
    yields exactly {!create}'s [Init] state — that is first boot, and it keeps working. [?on_commit_advanced]
    and the trailing [()] mean exactly what they mean on {!create} (see there) — including that
    nothing is reported retroactively for the [commit_number] this constructor RECOVERS, which is
    the case a restart-time consumer has to handle for itself.

    {b Raises [Invalid_argument] — fail-stop — if the superblock is unusable while the WAL is NOT
    empty}, i.e. if [superblock_read] returns [None] (fewer than a majority of copies verify and
    agree) OR returns bytes that do not decode as this module's own superblock record, while
    [wal_highest_op_number > 0]. {b This is an ordinary crash state, not an exotic one}:
    {!Riptide_storage.Storage_intf.S.superblock_write} is implemented by
    {!Riptide_storage.File_storage} as 3 sequential, non-atomic copy writes, so a crash partway
    through leaves fewer than 2 copies agreeing while the WAL is fully intact.

    The alternative — silently starting at [(view_number, last_normal_view, op_number,
    commit_number) = (0, 0, 0, 0)] and truncating the WAL to match, which is what this function
    used to do — is the single most dangerous state this protocol has, and it destroys committed
    data CLUSTER-WIDE rather than merely losing this replica. {!handle_message}'s [Do_view_change]
    dispatch treats every op-number above a sender's own [n] as PROVABLY ABSENT (VSR.tla's
    [CanNack]), which is sound only because a durably-written slot can never read back absent
    (VSR.tla:742-745's [StorageWellFormed]). A replica reporting [n = 0] over a WAL that still
    holds its entries breaks exactly that: it proves absent every op it durably held, and one such
    replica plus one honest nack is a nack quorum that truncates a committed, client-acknowledged
    value everywhere. `spec/tla/VSR.tla`:111-150 records TLC refuting precisely this mutation
    ([NoCommittedOpProvablyAbsent] violated at depth 6).

    {b The refusal is a total no-op on durable state} — nothing is written, nothing is truncated,
    the log is left exactly as it was found — so whatever rebuilds the superblock (or replaces the
    backend wholesale and lets a [StartView] refill it) still has everything to work from.
    Choosing between those is an operator/deployment decision this constructor deliberately does
    not make on its caller's behalf. {b The former is now a real, callable entry point} (Task 13,
    audit-remediation): {!Riptide_storage.Storage_intf.S.superblock_rebuild_from_wal} (concretely
    {!Riptide_storage.File_storage.superblock_rebuild_from_wal}) writes a fresh, usable superblock
    over the lost one — call it on the SAME backend this constructor was just given, then retry
    {!restart}.

    {b That repair is a tool of last resort run by a human, not an automatic self-heal, and it takes
    three REQUIRED arguments it cannot derive} (Task 13 fix round): [~view_number],
    [~last_normal_view] and [~commit_number] must be this replica's real durable view/commit state,
    obtained out of band from a live, trusted, surviving peer of the same cluster. Only [op_number]
    comes from the WAL. Supplying zeros — which the repair's first cut silently did on its own —
    reintroduces exactly the cluster-wide committed-data loss this guard exists to prevent, by a
    different route than the [n = 0] one above: a replica rebuilt with [last_normal_view] lower than
    the truth loses view-change log selection (highest [last_normal_view] wins) to a peer that
    honestly reports a higher one over a SHORTER log, so the new view's log is reconstructed without
    the committed op. Pinned by a running three-replica trace test, both directions — see that
    function's own doc comment for the trace, the per-field reasoning, and the limitations it
    discloses (including which shape of unusable superblock it cannot repair at all).

    {b DURABLE, recovered here} (VSR.tla:592-596): the log (from the WAL), [op_number],
    [commit_number], [view_number], [last_normal_view]. The last two are Decision 4's whole point
    — persisted rather than reconstructed by VSR's textbook in-memory Recovery sub-protocol.

    {b VOLATILE, deliberately lost} (VSR.tla:599-601): [peer_op_number], [recv_svc], [recv_dvc],
    [sent_dvc]. All in-memory view-change bookkeeping; a restarted replica re-collects it. Note in
    particular that clearing [sent_dvc] means a restarted replica WILL send a second
    [Do_view_change] for an episode it had already spoken in — which is exactly why
    [HasDvcQuorum] must count distinct senders rather than messages (VSR.tla:473-487).

    {b [status] is RECONSTRUCTED, never stored}: [view_number > last_normal_view] means this
    replica was mid-view-change when it went down and resumes there ([View_change]); otherwise
    [Normal] (VSR.tla:596-597, :680-682).

    Two reconciliations the abstract model does not need, both conservative in the safe direction:
    WAL entries beyond the durable [op_number] (a crash between the entry's write and the
    superblock's) are discarded, since they were never acknowledged; and the in-memory log is
    rebuilt only up to the first unreadable slot, while [op_number] keeps its full durable value —
    so {!op_number} can legitimately exceed [List.length (entries t)] after a restart that
    discovered corruption. See {!op_number}. *)

val primary_of_view : replica_count:int -> int -> int
(** [primary_of_view ~replica_count v] is VSR.tla's own [Primary(v) == 1 + ((v-1) % ReplicaCount)]
    (VSR.tla:18) for an ARBITRARY view [v] — not necessarily any particular replica's own current
    {!view_number}. {!primary} below is the common case (a replica's own current view) expressed
    as a thin wrapper over this. Added for audit-remediation Task 3's Finding 3: a [Start_view]
    message names its OWN view [v] in its [v] field, which need not equal the receiving replica's
    current {!view_number} (VSR.tla:295's guard is [m.v >= View(r)], not [m.v = View(r)] — see
    {!handle_message}'s [Start_view] case), so checking "is the sender really Primary of the view
    THIS MESSAGE is about" requires computing [Primary] of the message's own [v], not of the
    receiver's. See {!primary}'s own doc comment for the Euclidean-vs-truncating-modulo trap this
    is normalized against. *)

val primary : t -> int
(** [primary t] is [primary_of_view ~replica_count:t.replica_count (view_number t)] — VSR.tla's
    own [Primary(View(r)) == 1 + ((View(r)-1) % ReplicaCount)] (VSR.tla:18) evaluated against
    [t]'s current {!view_number} — a pure, computed function of state, never a stored field. See
    this module's own top-level scope note for the Euclidean-vs-truncating-modulo trap this
    implementation is normalized against, and for why [view_number = 0]'s primary is
    [replica_count], not [1]. *)

val is_primary : t -> bool
(** [is_primary t] is VSR.tla's own [r = Primary(View(r))] test — exactly [t.my_id = primary t]. *)

val op_number : t -> int
(** [op_number t] is VSR.tla's [rep_op_number[r]] (VSR.tla:53) — {b durable} state, recovered from
    the superblock by {!restart}.

    {b This changed with the storage-fault-tolerant-recovery work, and the change is visible
    here.} It used to be defined AS the in-memory log's length, which made
    [LogLengthMatchesOpNumber] (VSR.tla:728-729) true by construction. That definition cannot
    survive real storage faults: [rep_op_number] is durable across a restart while individual log
    entries may come back unreadable, and VSR.tla:358-359 turns on exactly that gap ("[n] — its
    op-number, which it still knows from durable superblock state even when some slot bodies are
    unreadable"). So this is now its own field, and the two can differ in exactly one documented
    way: after a {!restart} that discovered a corrupt slot, [op_number t] is the full durable
    op-number while [entries t] holds only the readable prefix. In every other state they agree,
    and every writer in this module maintains that in the same step. A replica in the
    differing state declines new client requests and new [Prepare]s until a [StartView] repairs
    it (state transfer is out of scope — see [spec/tla/README.md]'s known simplifications). *)

val commit_number : t -> int
(** [commit_number t] is VSR.tla's [rep_commit_number[r]] (VSR.tla:25) — the highest op-number
    this replica has confirmed committed. Monotonically non-decreasing over this replica's
    lifetime (both {!handle_message}'s [Prepare] handling and its internal
    [PrimaryExecuteOp]-driving logic only ever raise it, matching VSR.tla's own
    [CommitNumberNeverHigherThanOpNumber] invariant, VSR.tla:330-331, together with the fact
    that [rep_commit_number] is never assigned a lower value anywhere in the spec's normal-case
    actions).

    {b [commit_number t <= op_number t] holds for every reachable state, including against a
    network-corrupted/adversarial [Prepare], [DoViewChange] or [StartView]}, not merely for
    well-formed input: VSR.tla:118's own
    [rep_commit_number' = IF m.k > @ THEN m.k ELSE @] is safe in the TLA+ model only because every
    [Prepare] there is produced by [ReceiveClientRequest] itself, which guarantees [m.k < m.n]
    (VSR.tla:106-109's own comment) — a precondition that does not hold for a [Prepare] decoded
    off {!Riptide_transport.Transport_intf.S}'s own "no payload integrity" wire. {!handle_message}
    bounds it explicitly by REJECTING (not capping/clamping) a [Prepare]'s [k] once it
    reaches [op_number t] (this replica's own log length, which the [Prepare] being
    processed has just extended to [m.n]) — [commit_number] is left at its prior, legitimately-
    established value rather than substituted with a different one. The same discipline is applied
    to every other field that can move [commit_number] off the wire: a [DoViewChange] is rejected
    unless [0 <= k <= n] and [n] equals its own log's length, a [StartView] likewise plus a refusal
    to adopt a log shorter than this replica's own committed prefix, and [SendSV] refuses outright
    (rather than clamping) if the [HighestCommitNumber] maximum exceeds the winning log's length.
    See {!handle_message}'s own doc comment for each guard's exact bound and the TLC evidence that
    each is inert for correct traffic.

    {b For a [Prepare] specifically, only that one field's effect is discarded — the message itself
    is NOT treated as suspect}:
    [m.v] is still appended at [m.n] and a [Prepare_ok{n = m.n}] is still unicast back to the
    primary, exactly as for any in-order [Prepare]. Dropping the whole message instead would open
    a gap in this replica's log that nothing in this plan's scope (no state transfer, no retry)
    could ever repair. Rejecting rather than CLAMPING the [k] update is the real point of the
    design: a clamp would target [op_number t], i.e. the maximum legal value, so a single
    corrupted integer would let a backup declare its entire log committed — invariant-preserving
    and still completely wrong. See {!handle_message}'s own doc comment below for the exact bound, and the
    analogous, independently-established bound on a [Prepare_ok]'s own [n] field (a genuine ack
    can never claim to have acked an op-number this primary hasn't itself assigned).

    {b Monotonic over this replica's lifetime with exactly one exception, [SendSV]}: every
    normal-case path only ever raises [commit_number], and {!handle_message}'s [Start_view]
    dispatch ([ReceiveSV]) is explicitly monotonic too (VSR.tla:298-299's [IF m.k > @ THEN m.k ELSE
    @] — research §5.7 Part 4's documented fix for a real published double-application defect, not
    an incidental choice). [SendSV] is the one action that assigns [commit_number] unconditionally
    (VSR.tla:274): the new primary starts the view fresh from a quorum's worth of [DoViewChange]s,
    so its new value is [HighestCommitNumber] over that quorum, not a maximum with its own prior
    value.

    {b This unconditional assignment is a disclosed, knowingly unguarded hazard, not merely a
    non-monotonicity note}: unlike {!handle_message}'s [Start_view] dispatch (a BACKUP adopting a
    [StartView] it did not send, which refuses one whose [n] is below its own [commit_number] —
    see that dispatch's own doc comment), [SendSV]'s primary-side assignment has no such guard, and
    the new primary is not guaranteed to be part of its own DVC quorum. See [replica.ml]'s own
    comment at the [try_send_sv] assignment site for the full reasoning and why it is disclosed
    rather than fixed in this plan. *)

val view_number : t -> int
(** [view_number t] is VSR.tla's [rep_view_number[r]] (VSR.tla:30), i.e. [View(r)]. Starts at [0]
    (VSR.tla's own [Init]) and advances via three REAL actions —
    {!check_timeout} ([TimerSendSVC]), {!handle_message}'s [Start_view_change] dispatch
    ([ReceiveHigherSVC]), and its [Start_view] dispatch ([ReceiveSV], which ADOPTS [m.v] rather
    than incrementing) — in addition to the test-only {!for_test_set_view_number}/
    {!for_test_set_view}. Exposed read-only, the same way {!op_number}/{!commit_number} are, since
    it is genuine protocol state, not a test-only concern. *)

val last_normal_view : t -> int
(** [last_normal_view t] is VSR.tla's [rep_last_normal_view[r]] (VSR.tla:31) — the paper's own
    [v'], deliberately NOT derivable from {!view_number} in general (see [replica.ml]'s own doc
    comment on the field). [TimerSendSVC]/[ReceiveHigherSVC]/[ReceiveMatchingSVC]/[SendDVC]
    (VSR.tla:161-228) all leave it UNCHANGED; the two actions that assign it for real are
    [SendSV] (to [View(r)], VSR.tla:276 — i.e. the view this replica is starting as its new
    primary) and [ReceiveSV] (to [m.v], VSR.tla:302), both of which set [status = Normal] in the
    same step. It also changes via {!for_test_set_view_number} (which force-syncs it to
    {!view_number}, valid only while [status = Normal] — see that function's own doc comment) or
    {!for_test_set_view} (which sets it independently, valid for any [status], including
    [View_change] — see its own doc comment for why {!for_test_set_view_number} must NOT be reused
    for that case).

    {b [status = View_change] implies [last_normal_view < view_number], strictly} — exhaustively
    TLC-confirmed against `spec/tla/VSR.tla` (invariant
    [status = "ViewChange" => last_normal_view < view_number], no violation across all 264,376
    distinct reachable states), and load-bearing here rather than incidental: {!handle_message}'s
    [Do_view_change] dispatch REJECTS a [DoViewChange] whose [last_normal_view] is not strictly
    below its own [v], because that field is the primary sort key [WinningDVC] selects the
    surviving log by. Exposed read-only for the same reason {!view_number} is: genuine protocol
    state a caller (this module's own [SendDVC] logic, or a test asserting either of the two
    invariants above) may need to inspect. *)

val status : t -> status
(** [status t] is VSR.tla's own [rep_status[r]] (VSR.tla:29). Starts [Normal] ({!create}, VSR.tla's
    own [Init]); {!check_timeout} ([TimerSendSVC]) and {!handle_message}'s [Start_view_change]
    dispatch ([ReceiveHigherSVC]) are the ONLY two actions that move it to [View_change], and both
    reset [recv_svc]/[recv_dvc]/[sent_dvc] in the same step (VSR.tla:168-170, 189-191). The two
    that move it BACK to [Normal] are [SendSV] (driven internally from {!handle_message}'s
    [Do_view_change] dispatch) and [ReceiveSV] ({!handle_message}'s [Start_view] dispatch) —
    neither of which can ever move it INTO [View_change], per VSR.tla:275 and :301. That asymmetry
    is what makes the stale entries [ReceiveSV] deliberately leaves in [recv_dvc]/[recv_svc]
    unreadable; see {!handle_message}'s own doc comment. Also settable directly, for tests, via
    {!for_test_set_view} (and, restricted to
    [Normal], implicitly by {!for_test_set_view_number}, which never touches [status] at all since
    it is already [Normal] on every replica {!for_test_set_view_number} is meant to be used
    against). *)

val entries : t -> Riptide.Value.value list
(** [entries t] is this replica's log in append order (op-number 1 first) — a thin wrapper over
    {!Riptide_vsr.Replica_log.to_list}, exposed read-only for tests/callers to inspect resulting
    state after {!propose}/{!handle_message} calls. *)

val is_committed : t -> Riptide.Value.value -> bool
(** [is_committed t v] is true iff [v] appears in this replica's log at some op-number [<=]
    {!commit_number}. Compares by {!Riptide.Value.canonical_encode} equality, not OCaml structural
    [=] — see {!propose}'s own doc comment for why: [Value.value]'s [Float] case is
    content-addressed by raw bit pattern (`lib/value.mli`), and this module stays consistent with
    that identity notion throughout rather than introducing a second one. *)

val propose : t -> Riptide.Value.value -> unit
(** [propose t v] is VSR.tla's [ReceiveClientRequest(v)] (VSR.tla:91-102) — the entry point an
    application/client-facing layer calls to submit a new value to this replica.

    {b No-op, not an error, unless [IsNormalPrimary(r)] holds} — VSR.tla:48's own
    [status[r] = "Normal" /\ Primary(View(r)) = r], conjoined into [ReceiveClientRequest] at
    VSR.tla:93: this is now a real TWO-part guard (an earlier, normal-case-only plan's version
    only checked the second half, since [status] didn't yet exist as real state) — when a guard in
    the TLA+ model doesn't hold, the action simply isn't enabled and nothing happens; there is no
    "reject with an error" step anywhere in the spec for this case for {!handle_message} to mirror
    ([Malformed_message]/[Out_of_order_append] are a different case — see {!handle_message} —
    genuine adversarial/network conditions the spec deliberately doesn't model at all, not a guard
    failure within the model). Use {!is_primary} first if the caller needs to distinguish "was
    rejected because I'm not the primary" from "was accepted"; combine with {!status} (now a real
    accessor — see its own doc comment) if the caller also needs to distinguish the
    [status <> Normal] rejection case.

    {b Also a no-op if [v] is already present anywhere in this replica's log} — VSR.tla's own
    dedup guard, [v \notin { rep_log[r][i] : i \in DOMAIN rep_log[r] }] (VSR.tla:94), checked here
    via {!Riptide.Value.canonical_encode} equality (equivalently, {!Riptide.Value.content_hash}
    equality) over {!Riptide_vsr.Replica_log.to_list}, deliberately NOT OCaml's structural [=] on
    [Value.value] — [lib/value.mli]'s own [Float] case is content-addressed by raw IEEE-754 bit
    pattern, not by either OCaml's [=] or [compare] (which disagree with each other on
    [nan]/[-0.0] too), so canonical-encoding equality is [Value]'s own single source of truth for
    "is this the same value" and this module stays consistent with it rather than introducing a
    second identity notion.

    Otherwise: appends [v] to the log at [op_number t + 1], then broadcasts
    [Prepare{view=view_number t; n=op_number t + 1; v; k=commit_number t}] (VSR.tla's [Broadcast],
    VSR.tla:64, 98-99) to every OTHER replica [1..replica_count] (i.e. every id in that range
    except this replica's own [my_id] — VSR.tla's [BroadcastFunc]'s own [replicas \ {source}],
    VSR.tla:56), via [create]'s [send] closure, once per destination.

    Also drives VSR.tla's [IsCommitted]/[PrimaryExecuteOp] (VSR.tla:139-155) internally afterward,
    the same incremental check {!handle_message}'s own [Prepare_ok] handling drives (see its doc
    comment for the exact algorithm) — needed because [PrimaryExecuteOp]'s guard has two
    conjuncts, and [propose] is the action that changes the FIRST one
    ([rep_commit_number[r] < rep_op_number[r]], VSR.tla:148), not [ReceivePrepareOkMsg]. For
    [replica_count >= 3] (so [f >= 1]) this call is a provable no-op — a freshly-appended op has
    zero acks and can never immediately satisfy [IsCommitted] — with one exception: the degenerate
    [replica_count = 1] cluster ([f = 0]), where [IsCommitted] is vacuously true for every
    op-number and this replica commits its own proposal immediately, with no acks needed at all,
    matching what VSR.tla's own [Next] would allow. *)

val check_timeout : t -> unit
(** {b Two actions behind one entry point, selected by [status]} — the second added by the
    storage-fault-tolerant-recovery work:

    - [status = Normal]: VSR.tla's [TimerSendSVC] (VSR.tla:302-315), described in full below.
    - [status = View_change]: VSR.tla's [ForfeitViewChange] (VSR.tla:542-556) — the escape hatch
      for a coordinator that holds a full [f+1] [DoViewChange] quorum and STILL cannot complete,
      because some op in the candidate range is neither reconstructible from the quorum's readable
      entries nor proven absent by a nack quorum. It bumps to [view + 1], clears the view-change
      bookkeeping and broadcasts [StartViewChange], so a replica whose own storage may be intact
      gets to coordinate instead; it deliberately does NOT return to [Normal] (this replica's
      durable view has already advanced), and it deliberately does nothing at all below a quorum
      (more [DoViewChange]s can only add evidence, so forfeiting early would abandon an attempt
      that was still making progress — VSR.tla:528-531).

      In the spec this is a free-firing [Next] disjunct; here it is timer-driven, because firing
      it the instant a quorum is reached would abandon completable view changes whenever the
      resolving message is merely a few microseconds behind the quorum-completing one
      (VSR.tla:536-537 says a real implementation bounds it with a timer, and this is that). It
      shares [svc_limit] as its budget with [TimerSendSVC] — both are "give up on this view and
      try a newer one", and both budgets are reset by a successful return to [Normal].

    The two are disjoint by construction ([TimerSendSVC] requires [Normal], the forfeit path
    requires [View_change]), so one call can never trigger both, and a caller never has to know
    which recovery action is currently applicable — it only has to report that nothing is
    progressing.

    [check_timeout t] is VSR.tla's [TimerSendSVC] (VSR.tla:161-174) — the entry point a caller
    invokes when it decides (by whatever real wall-clock/timer policy it uses — VSR.tla itself
    deliberately does not model real timeouts, per research §2.1's own comment quoted at
    VSR.tla:158-159) that this replica has gone too long without hearing from its current primary
    and should try to start a view change.

    {b No-op, not an error, unless BOTH [svc_count t < svc_limit] (the [~svc_limit] {!create} was
    given) AND [status t = Normal] hold} — VSR.tla:163-164's own two-conjunct guard,
    [aux_svc_count[r] < StartViewOnTimerLimit /\ rep_status[r] = "Normal"]. As with every other
    guard in this module, a failing guard means the action simply isn't enabled: no exception, no
    state change, nothing sent.

    {b The [status t = Normal] conjunct is a real, disclosed liveness gap, not just a guard}: a
    replica that has already moved to [View_change] has NO mechanism anywhere in this module to
    re-arm and try a NEWER view on its own, even if the view it's currently attempting also turns
    out to have a dead primary. Two consecutive dead [Primary]-designates (e.g. a backup dies, then
    the primary dies, and the next view's own [Primary] happens to be that already-dead backup) can
    therefore wedge an entire live-quorum cluster in [View_change] PERMANENTLY — every further
    {!check_timeout} call is a no-op, safety is completely unaffected (nothing committed is ever
    lost or diverges), but no replica ever becomes primary again. See [spec/tla/README.md]'s "Known
    simplifications, not omissions" list, point 3, for the full explanation, why this is
    liveness-only, and why fixing it is real, separate design work out of scope here; see
    [test/test_vsr_replica_view_change.ml]'s own regression test for a real, running reproduction.

    {b A related, MORE reachable gap, sharing this same broad root cause} (no replica in this
    module ever sends a [Start_view_change] once it has left [Normal] status, by any path):
    [ReceiveHigherSVC] (see {!handle_message}'s own doc comment, its [Start_view_change] dispatch
    section) adopts a higher view it hears about from someone else's [Start_view_change] but never
    re-broadcasts one of its own. A caller driving this function from a real per-replica wall-clock
    timer (this module's own intended shape) MUST NOT assume that one replica detecting a dead
    primary is always enough to recover the cluster on its own: with the survivors split between
    active timer-firers and passive adopters, completing a view change can require as many as
    [f + 1] of them to have fired [check_timeout] independently — worst case, exactly the dead-
    primary scenario point 3 already covers — even though a fully-live cluster with no crash at
    all needs only [f]. Survivors' timers firing at different times is the ordinary case for
    independent real timers, not an edge case, and a timer policy that assumes "the first replica
    to notice is enough" can wedge the cluster permanently on a SINGLE primary failure, with no
    second failure required. See [spec/tla/README.md]'s same "Known simplifications, not
    omissions" list, point 4, for the full mechanism and a live reproduction.

    Otherwise: advances [view_number] to [view_number t + 1], moves [status] to [View_change],
    resets [recv_svc] to empty, [recv_dvc] to empty, and [sent_dvc] to [false] (VSR.tla:166-170 —
    all four together mark the start of a fresh view-change episode), increments the replica's own
    [svc_count] by one, and broadcasts [Start_view_change{v = view_number t; i = my_id}] (VSR.tla's
    own [Broadcast], VSR.tla:172) to every OTHER replica, exactly like {!propose}'s own broadcast.

    {b [svc_count]'s bound is NOT permanent}, despite VSR.tla's own [aux_svc_count] never resetting
    anywhere in the abstract spec (research §6.3 point 4: [aux_svc_count] exists there purely to
    keep TLC's own state space finite, not as real protocol state) — literally transcribing "never
    resets" would mean a real replica permanently gives up trying to trigger a view change after
    [svc_limit] timeouts, for the rest of its lifetime, which is wrong for a real long-running
    deployment that needs to recover from repeated primary failures. This is a DELIBERATE,
    DISCLOSED divergence from the literal TLA+ transcription (not an oversight): [svc_count] resets
    to [0] whenever this replica successfully returns to [Normal] status by actually COMPLETING a
    view change — via [SendSV] (becoming the new primary itself) or [ReceiveSV] (accepting a new
    primary's [StartView]) — since reaching a working view again proves the replica can recover,
    making any FUTURE timeout a genuinely new failure that deserves its own fresh budget. Both
    resets are implemented, at the exact point each action sets [status' = "Normal"] (VSR.tla:275,
    301), and they are deliberately NOT symmetric: [SendSV]'s is unconditional (its own guard
    already requires [status = View_change], VSR.tla:267, so it can only fire on a real transition),
    while [ReceiveSV]'s fires ONLY on an actual [View_change → Normal] transition. [ReceiveSV]'s
    guard is [m.v >= View(r)] with no status conjunct (VSR.tla:295), so it genuinely re-fires on a
    duplicated or replayed [StartView] for a view this replica is already [Normal] in — and
    [lib/sim/network.ml] injects real duplicates. An unconditional reset there would let such
    duplicates refresh this budget indefinitely, silently nullifying the [svc_limit] bound the whole
    mechanism exists to enforce.

    Also internally drives VSR.tla's [SendDVC] (VSR.tla:216-228) the same way {!handle_message}'s
    [Start_view_change] dispatch does — see {!handle_message}'s own doc comment for the general
    mechanism; this call only has an observable effect in the degenerate [replica_count = 1]
    ([f = 0]) cluster (see [replica.ml]'s own comment on [try_send_dvc] for why). *)

exception Sender_mismatch of string
(** Raised by {!handle_message} — see its own doc comment for exactly when and why — on a mismatch
    between a decoded message's own claimed sender and the transport-authenticated [~sender] it
    actually arrived from. {b Audit-remediation Task 3, Finding 1 of the fix round}: this used to
    be a bare [Invalid_argument], overloading the same exception {!durable_append}'s own escape
    hatch uses for a completely different condition (an unclassified backend refusal that must
    NEVER be laundered into "the protocol declined an op" — see [replica.ml]'s comment at that
    raise site). A caller whose dispatch loop absorbs [Invalid_argument] to stay total against a
    sender mismatch (see below) could not, with one shared exception type, avoid ALSO absorbing a
    genuine backend-contract violation — this distinct exception is what lets a caller catch
    exactly the sender-mismatch case and let everything else propagate unchanged. *)

val handle_message : t -> sender:int -> string -> unit
(** [handle_message t ~sender bytes] decodes [bytes] via {!Riptide_vsr.Message.decode} and
    dispatches.

    {b [sender] (audit-remediation Task 3) is the transport-authenticated identity of whoever
    actually holds the connection [bytes] arrived on} — Task 1's
    {!Riptide_transport.Transport_intf.S.receive}'s own [string * int] result, threaded through
    unmodified by every real caller (see {!Riptide_dst.Cluster}'s dispatch loop). Before ANY of
    the per-message-type dispatch described below runs, [handle_message] cross-checks [sender]
    against that message's OWN claimed sender — [source] on [Prepare]/[Start_view], [i] on
    [Prepare_ok]/[Start_view_change]/[Do_view_change] — and {b raises {!Sender_mismatch} on a
    mismatch, as a total no-op: no state mutation, no reply sent}, for every message type, not
    just the two ([Prepare]/[Start_view]) that gained a sender field specifically for this. This
    closes one major piece of the audit's single highest-severity finding: previously
    [Prepare]/[Start_view] carried no sender claim to even check, and even the message types that
    DID carry one ([i] on the three above) had nothing cross-checking that claim against who
    actually sent the bytes, so one legitimate replica could spoof another's [i] to manufacture a
    fake commit/view-change quorum, or (with [Start_view] previously uncheckable at all) a single
    forged message could rewrite the entire cluster's committed log.

    {b This closes attribution forgery, but NOT role forgery} — see Finding 3, described on
    [Prepare] and [Start_view] below, for the other half: a real, correctly-attributed sender
    that simply has no business sending that message type at all (not the current view's primary)
    is a separate, independently-checked condition.

    This is deliberately a RAISE, not the silent drop every in-dispatch guard below uses for a
    protocol-stale-but-honestly-attributed message (a late [Prepare], a wrong-view [Prepare_ok]):
    those guards reject the normal, expected cost of an unreliable network, while a sender
    mismatch means the identity claim itself cannot be trusted — a caller should be able to
    observe it as a distinct, exceptional condition rather than have it vanish indistinguishably
    from ordinary staleness. A caller whose dispatch loop must stay total in the face of
    adversarial input (e.g. {!Riptide_dst.Cluster}'s fault-injecting simulation) catches
    {!Sender_mismatch} around this call, the same way it already absorbs
    {!Riptide_vsr.Message.Malformed_message} for an undecodable payload.

    The per-message-type dispatch itself, once the sender check above has passed:

    - A [Prepare] message drives VSR.tla's [ReceivePrepareMsg] (VSR.tla:110-123): a backup-side
      handler ([IsNormalBackup(r)] == [status[r] = "Normal" /\ Primary(View(r)) # r], VSR.tla:49 —
      a no-op if [status t <> Normal] OR if [t] IS the primary; an earlier, normal-case-only plan's
      version only checked the primary half), gated on [m.view = view_number t] and, per VSR.tla's
      own strict-order guard [rep_op_number[r] + 1 = m.n] (VSR.tla:115), on the message's [n]
      being exactly [op_number t + 1]. {b Also gated (Finding 3, audit-remediation Task 3 fix
      round) on [source] equaling {!primary} t}: [handle_message]'s own cross-check above only
      proves [source] is who transport-authenticated [sender] really is, never that this real,
      credentialed replica had any business sending a [Prepare] at all — a [Prepare] is only ever
      legitimate from the CURRENT view's primary, and this closes the other half of the audit's
      highest-severity finding (a genuine cluster member, under its own true identity, sending a
      message type it has no role-based right to send). [primary t], not [primary_of_view] of the
      message's own [view] field, is the right comparison specifically because the [m.view =
      view_number t] guard just above already forces them equal for anything that reaches this
      point. A message failing this is dropped, total no-op, exactly like the out-of-order case
      just below. {b An out-of-order [Prepare] (too high, too low, or a gap)
      is silently dropped} — log unchanged, no [Prepare_ok] sent, no exception raised to the
      caller — exactly matching VSR.tla's own behavior of simply not enabling this action for a
      mismatched [n]: there is no buffering, reordering, or retry logic anywhere in this module's
      (or the underlying spec's) scope. {b This is a real, disclosed liveness gap}, not a defect: a
      backup that misses one [Prepare] has no way to catch up in this module's scope (no
      COMMIT-message resend, no state-transfer, no retry — those are explicitly out of scope for
      `spec/tla/VSR.tla` itself, per `spec/tla/README.md`). On success: appends [m.v] at [m.n],
      advances [commit_number] to [m.k] if higher AND if [m.k < op_number t] (i.e. [< m.n], since
      [op_number t] has just become [m.n]) — never regresses it (VSR.tla:118's own [IF m.k >
      @ THEN m.k ELSE @]), and never lets it reach or exceed what this replica's own log actually
      contains, even for a [Prepare] whose [k] a corrupted/forged network delivery has pushed to or
      past [n] (VSR.tla's own [m.k < m.n] precondition, VSR.tla:106-109, holds for every [Prepare]
      the TLA+ model itself can produce, but rather than trust it this module enforces its own
      explicit bound, [m.k < m.n], matching that precondition exactly — see {!commit_number}'s own
      doc comment and [replica.ml]'s comment at the bound itself for the full reasoning). An
      earlier version of this bound admitted [m.k = m.n] as a defense-in-depth margin, justified
      solely by [k = n] being harmless while a backup's [commit_number] was purely local state —
      once view-change wired a backup's [commit_number] into [DoViewChange.k] and
      [HighestCommitNumber] (a SEPARATE maximum over all valid DVCs, feeding the new primary's own
      [commit_number] and then [StartView.k] cluster-wide), that margin stopped being benign, so
      the bound was tightened to reject [m.k = m.n] too — see [test/test_vsr_replica.ml]'s own
      k-boundary tests, which pin all three of [m.k = m.n - 1] (accepted), [m.k = m.n] (rejected),
      and [m.k = m.n + 1] (rejected).

      Then unicasts [Prepare_ok{view=view_number t; n=m.n; i=my_id}] back to {!primary}'s current value (NOT a
      stored [primary_id] any more — computed fresh from [view_number t] at reply time).
    - A [Prepare_ok] message drives VSR.tla's [ReceivePrepareOkMsg] (VSR.tla:126-136): a
      primary-side handler ([IsNormalPrimary(r)] == [status[r] = "Normal" /\ Primary(View(r)) =
      r] — a no-op if [status t <> Normal] OR if [t] is not the primary), gated on [m.view =
      view_number t] AND on [m.i] being a valid replica id in [1, replica_count] — VSR.tla:141's
      own [p \in replicas] domain restriction on the set [IsCommitted] counts over (VSR.tla:15's
      [replicas == 1..ReplicaCount]), enforced here at the point [m.i] would otherwise enter
      {!t}'s internal peer-acknowledgment table, so a decoded [Prepare_ok] naming no real replica
      (a corrupted or forged [i]) can never inflate quorum. A [m.i] that fails this check is
      dropped exactly like a wrong-view message — no state change. {b Also gated on [m.n] not
      exceeding [op_number t]}: op-numbers are minted only by this primary's own log (this
      replica IS the primary in this branch), so a genuine ack can never legitimately claim a
      higher one — a [m.n] a corrupted/forged network delivery has pushed past what this replica
      has itself ever proposed is dropped too, for the same reason (and same
      [AcknowledgedWritesExistOnMajority] concern) as the [m.i] check just above: left unbounded,
      it would let a single forged ack from an otherwise-real replica id permanently pre-ack every
      future op this primary ever proposes. Otherwise: updates this
      replica's tracked high-water mark for peer [m.i] to [m.n], but ONLY if higher than what was
      already recorded (VSR.tla:131-132's own [IF m.n > @ THEN m.n ELSE @]) — cumulative, not
      per-op, per VSR.tla's own §1.5 point 2 comment (VSR.tla:125). Then internally drives VSR.tla's
      [IsCommitted]/[PrimaryExecuteOp] (VSR.tla:139-155) — the same check {!propose} also drives
      (see its own doc comment for why both must: [PrimaryExecuteOp]'s guard has two conjuncts,
      and this action is the one that changes the SECOND, [IsCommitted(r, next)], by changing
      [rep_peer_op_number]). The advance is applied INCREMENTALLY: starting from
      [commit_number t + 1], repeatedly check [IsCommitted(r, next)] — [f] OTHER replicas (VSR.tla
      [f = (ReplicaCount-1) \div 2], VSR.tla:140) with a recorded high-water mark [>= next] — and
      if true, advance [commit_number] to [next] and continue to [next+1]; stop at the first
      [next] that is not yet committed, or once [commit_number = op_number t]. {b This never
      jumps straight to the just-arrived message's own [n]} even when that [n]'s own quorum
      threshold is independently satisfied — every intermediate op-number between the old
      [commit_number] and the new one is individually checked and individually advanced through,
      exactly one at a time, matching VSR.tla's own [PrimaryExecuteOp] action, which only ever
      advances [rep_commit_number] by exactly one per firing (VSR.tla:149,151) and must fire
      repeatedly, once per increment, to cover a gap of more than one. (Checking only the
      arrived message's own [n] instead is a real bug this design avoids: e.g. if the OTHER
      replica whose acknowledgment would complete op-number [commit_number+1]'s own quorum hasn't
      been recorded yet under [n = commit_number+1] specifically — only under some non-cumulative
      combination that happens to also satisfy a higher [n] — a [n]-only check can miss advancing
      to [commit_number+1] even though it is, in fact, already committed.)
    - A [Start_view_change] message drives EITHER VSR.tla's [ReceiveHigherSVC] (VSR.tla:183-194)
      OR [ReceiveMatchingSVC] (VSR.tla:196-205), depending on how its [m.v] compares to
      {!view_number}'s current value — never both, and possibly neither:
      {ul
      {- [m.v > view_number t]: [ReceiveHigherSVC]. Adopted unconditionally (research's own
         "assume-mode, not increment-mode" — see VSR.tla's own comment at [ReceiveHigherSVC] for
         the citation) — no majority is needed to START tracking a higher view this way, unlike
         [SendDVC]'s own quorum requirement below. Sets [view_number] to [m.v], [status] to
         [View_change], seeds [recv_svc] with JUST the sender ([{m.i}], VSR.tla:189 — a fresh
         episode starts by "knowing about" only the one replica whose message triggered it), and
         resets [recv_dvc] to empty and [sent_dvc] to [false] (VSR.tla:190-191 — a genuinely new
         episode, exactly like {!check_timeout}'s own reset).}
      {- [m.v = view_number t /\ status t = View_change]: [ReceiveMatchingSVC]. Another
         [Start_view_change] for the SAME episode already running — unions the sender into
         [recv_svc] (VSR.tla:201's own [@ \cup {m.i}]; a sender already present has no further
         effect, since [recv_svc] is a genuine set, not a list — the same sender's message
         arriving twice must not inflate [SendDVC]'s own [Cardinality] count below). Leaves
         [view_number]/[status]/[recv_dvc]/[sent_dvc] untouched (VSR.tla:203-205).}
      {- Neither guard holds (e.g. [m.v < view_number t], or [m.v = view_number t] while
         [status t = Normal] — no episode is running here to join) — not enabled by anything,
         dropped, the same "no buffering/retry" discipline already established for an out-of-order
         [Prepare].}}
      {b Also gated on [m.i] being a valid replica id in [1, replica_count], EXCLUDING this
      replica's own id}, for both branches — not itself a VSR.tla guard (the abstract model's own
      [Broadcast] can only ever produce a well-formed, non-self [i]), but the same defense-in-depth
      this function's own [Prepare_ok] handling above applies to [m.i]: a decoded
      [Start_view_change] naming no real replica, OR naming this replica itself, must never be
      allowed into [recv_svc], which [SendDVC]'s own [Cardinality(recv_svc) >= f] check below
      treats as a raw member count — left unchecked, either would inflate that count for free
      (the self-addressed case is not even a forgery: this codebase's simulated transport has no
      self-delivery special case, so an ordinary broadcast genuinely loops back into the sender's
      own dispatch loop). A [m.i] failing this check drops the WHOLE message (no state change at
      all, not even adopting a higher [m.v]) — same "guard failure ⇒ total no-op" convention as
      every other guard in this module.

      {b [SendDVC] (VSR.tla:216-228) has no separate entry point of its own} — like
      [PrimaryExecuteOp] (see {!propose}'s own doc comment for the precedent), its guard
      ([status t = View_change /\ not (sent_dvc) /\ Cardinality(recv_svc) >= f], where
      [f = (replica_count - 1) / 2]) is checked internally after EVERY point [recv_svc] actually
      changes — the two branches above, and {!check_timeout}'s own reset — rather than polled from
      a separate call. When it fires: sends [Do_view_change{v = view_number t; log = entries t;
      last_normal_view = last_normal_view t; n = op_number t; k = commit_number t; i = my_id}]
      (VSR.tla's own [Send], VSR.tla:222-224) to {!primary}'s CURRENT value (which may be [my_id]
      itself, if this replica is the one about to become the new primary — VSR.tla's own [SendSV]
      comment, "f+1 DOVIEWCHANGE from different replicas, INCLUDING ITSELF", VSR.tla:262-263, is
      exactly why [SendDVC] doesn't exclude sending to self the way {!propose}'s broadcast excludes
      sending to other replicas), and sets [sent_dvc] to [true] so it cannot fire again for the
      same episode (VSR.tla:225's own comment on why this one-shot flag exists at all — without
      it, every firing would leave every guard conjunct unchanged, re-enabling itself forever).
    - A [Do_view_change] message drives VSR.tla's [ReceiveDVC] (VSR.tla:232-240), whose only guard
      is [ValidDvc(r, m) == m.v = View(r)] (VSR.tla:230) — the view-filtered DVC quorum-counting fix
      for the original formalization's own published 114-step safety counterexample. There is
      deliberately NO status conjunct (a DVC for this replica's current view accumulates even while
      [status = Normal]; the sole reader, [SendSV], carries the status check instead) and no
      "am I the primary" conjunct (VSR.tla relies on [m.dest]; a misrouted DVC simply accumulates
      where nothing reads it). A DVC for any OTHER view — higher or lower — is dropped; for a
      higher view that is a disclosed, liveness-only simplification inherited from the spec (a
      [DoViewChange] is unicast, so any view it could announce was broadcast to everyone as a
      [StartViewChange] first).

      {b The accumulator is keyed by SENDER ([m.i]), and the first arrival per sender per episode
      wins} — a deliberate, disclosed divergence from VSR.tla:34's literal [SUBSET [message]]
      (set-of-records) type, resolved in this task's brief and argued at length on [replica.ml]'s
      own [recv_dvc] field. In the abstract model the two coincide: a correct replica sends exactly
      one [DoViewChange] per episode and TLA+'s bag cannot corrupt anything. On a real wire they do
      not: [lib/sim/network.ml] injects both duplicates and corruption, so the same sender's DVC can
      arrive twice with different bytes, which a literal set-of-records would count as TWO elements
      toward [SendSV]'s [>= f + 1] threshold — while VSR.tla:262-263 requires "f+1 DOVIEWCHANGE from
      DIFFERENT replicas". First-wins (never last-wins) is likewise deliberate: a retransmission, a
      duplicate and a corrupted duplicate are indistinguishable here, so a later arrival must never
      overwrite an already-accepted earlier one.

      {b Every integer field is validated before being trusted}, the same discipline the [Prepare]/
      [Prepare_ok] arms above apply, since [Message.decode] confirms SHAPE only, never protocol-level
      legality: [i] must name a real replica in [1, replica_count] (VSR.tla:15) — but, unlike the
      [Start_view_change] arm, [i = my_id] is explicitly ALLOWED, because VSR.tla:224 addresses a
      [DoViewChange] to [Primary(View(r))] (this replica, whenever it is the new primary) and
      VSR.tla:262-263's quorum is "from different replicas, INCLUDING ITSELF"; [n] must be exactly
      the length of the [log] the same message carries (VSR.tla's [LogLengthMatchesOpNumber] applied
      to the sender — load-bearing, since [SendSV] adopts [winner.log] and relies on the resulting
      length BEING [winner.n]); [k] must satisfy [0 <= k <= n] (the sender's own
      [CommitNumberNeverHigherThanOpNumber]; note [<=] is correct here, unlike the [Prepare] arm's
      strict [k < n], because a DVC's [k]/[n] are one replica's commit- and op-number, which
      legitimately coincide); and [last_normal_view] must satisfy [0 <= last_normal_view < v] (see
      {!last_normal_view} — this is the field [WinningDVC] sorts by FIRST, so an unbounded value
      would let one forged DVC dictate the whole cluster's log). A message failing any of these is
      dropped wholesale.

      {b [SendSV] (VSR.tla:264-280) has no separate entry point of its own}, exactly like
      [PrepareOk]'s [PrimaryExecuteOp] and [Start_view_change]'s [SendDVC]: its guard
      ([status t = View_change /\ is_primary t /\ Cardinality(valid recv_dvc) >= f + 1]) is checked
      internally after every successful accumulation above — the only point that count can rise.
      No check is needed at the episode-reset points ({!check_timeout}, [ReceiveHigherSVC]) because
      both set [recv_dvc] to empty, and [f + 1 >= 1 > 0] for EVERY [replica_count], including the
      degenerate [f = 0] cluster. {b The threshold is [>= f + 1] (VSR.tla:269), not [SendDVC]'s
      [>= f] (VSR.tla:221)}, and the two are kept as separate expressions on purpose. When it
      fires, it performs two INDEPENDENT scans over the valid DVCs — never one derived from the
      other, per VSR.tla:244-245's own explicit warning: [WinningDVC] (VSR.tla:248-255) picks the
      lexicographic maximum by [(last_normal_view, n)] — largest [last_normal_view] first, ties
      broken by largest [n] — and [HighestCommitNumber] (VSR.tla:257-260) takes the maximum [k] over
      the same set, which routinely is NOT the winning DVC's own [k]. It then adopts [winner.log]
      (and therefore [winner.n]) wholesale, sets [commit_number] to that separate maximum, moves to
      [Normal] with [last_normal_view = view_number], resets [svc_count], and broadcasts
      [StartView{v = view_number t; log = winner.log; n = winner.n; k}] to every OTHER replica. One
      defensive guard has no counterpart in VSR.tla: if the two maxima disagree so badly that
      [k > winner.n] — impossible for any well-formed DVC set, TLC-confirmed inert over the spec's
      full 264,376-state graph — the whole action is refused with no state change, rather than
      clamping [k] down (a clamp targets the maximum legal value, i.e. it would declare the entire
      adopted log committed off one corrupted integer).
    - A [Start_view] message drives VSR.tla's [ReceiveSV] (VSR.tla:292-305). Guard: [m.v >= View(r)]
      — {b [>=], not [>]}, and with no status conjunct, so a [StartView] for the view this replica is
      already in is accepted and re-applied; only a strictly lower [m.v] is dropped. {b Also gated
      (Finding 3, audit-remediation Task 3 fix round) on [source] equaling [primary_of_view
      ~replica_count v] — [Primary] of the message's OWN [v], not of [t]'s current
      {!view_number}}: this is the exact reproduction of the audit's single highest-severity
      finding that [handle_message]'s attribution cross-check alone does NOT close — a real,
      correctly-attributed cluster member that simply is not Primary of the view it claims to be
      announcing could otherwise rewrite this replica's entire log with one well-formed
      [StartView], no spoofing required. [primary_of_view], not {!primary}, because a legitimate
      [StartView] routinely announces a view AHEAD of [t]'s own current one (that is the whole
      point of [>=] above) — checking against {!primary}'s value (Primary of the OLD view) would
      wrongly reject every genuine one. Checked before [n]/[log]/[k] are inspected at all; a
      message failing it is dropped, total no-op, before the guards described next even run.
      Effect: adopts
      [m.log] (and hence [m.n]) wholesale, sets [view_number] and [last_normal_view] to [m.v],
      returns [status] to [Normal], resets [svc_count] {b only on a real [View_change → Normal]
      transition} (see {!check_timeout}), and advances [commit_number] to [m.k]
      {b if and only if [m.k] is higher} (VSR.tla:298-299 — research §5.7 Part 4's documented fix for
      a real published double-application defect; never simplify this to an unconditional
      assignment). Field validation mirrors the [Do_view_change] arm: [v >= 0], [n] exactly the
      carried log's length, [0 <= k <= n], plus one guard with no counterpart in VSR.tla — a
      [StartView] whose log is SHORTER than this replica's own [commit_number] is refused outright,
      since adopting it would discard already-committed entries (TLC-confirmed inert for correct
      traffic: no reachable state of `spec/tla/VSR.tla` has a receivable, view-eligible [StartView]
      with [m.n < rep_commit_number[r]]).

      {b [recv_dvc] and [recv_svc] are deliberately NOT reset here} — VSR.tla:304 lists both as
      UNCHANGED, and `spec/tla/README.md` has the detailed, TLC-backed argument for why the stale
      entries this genuinely leaves behind can never be read (every reader is gated on
      [status = View_change]; both actions that reach that status reset both structures first).
      Adding a reset would deviate from the model this code must match, in a direction that model
      was never checked against. Do not "fix" it.
    - Any input that fails to decode (raises {!Riptide_vsr.Message.Malformed_message}) is treated
      the same as an out-of-order [Prepare]: silently dropped, no exception propagates to the
      caller. A real network provides no payload integrity ({!Riptide_transport.Transport_intf.S}'s
      own documented guarantee), and this replica must not crash when it is handed garbage. *)

(** {2 Observability}

    Unlike the test-support surface below, {!append_refusals} is production-facing: real callers
    are expected to read it, not just tests. *)

val append_refusals : t -> (string * int) list
(** [append_refusals t] is how many durable WAL appends this replica has had REFUSED over
    its lifetime, broken down by the reason, as [(name, count)] pairs in a fixed order:
    [fault_injection_cap], [entry_rejected], [out_of_sequence], [eviction_blocked],
    [storage_fault].

    {b Not protocol, but no longer test-only} — nothing in this module reads it, and all five
    refusals have exactly the same protocol effect (the entry is not durable, so it is not
    acknowledged). It was introduced as [for_test_append_refusals] because they used to be
    indistinguishable, which is final-review finding I2: one blanket [Invalid_argument] catch
    reported "the backend refused this entry" for three unrelated conditions, and nothing counted
    them, so the conflation was invisible. Instrumenting the suite before the fix recorded 317
    refusals in a single [dune test --force], 308 of one kind and 9 of another, none of them
    observable anywhere.

    Subtask 3.7 dropped the [for_test_] prefix, because the fourth shape below gave it a real,
    non-test consumer. {b The intended production use:} a caller that has supplied
    {!Riptide_storage.File_storage}'s [?may_evict] gate watches [eviction_blocked]'s count {e grow}
    — alongside {!commit_number} failing to advance — as the real signal that materialization has
    genuinely fallen behind the log, rather than inferring it from a stalled cluster. Either
    observation alone is ambiguous: a growing [eviction_blocked] with commit progress still
    advancing is healthy backpressure doing its job, and a stalled [commit_number] on its own has
    many other causes. It is their conjunction that identifies this one. The counts are monotonic
    and per-replica, so the useful reading is a delta between two samples, not an absolute value.

    - [fault_injection_cap] — {!Riptide_storage.Fault_injecting_storage}'s own deliberate
      ["faults_max exceeded"] guard. Not a storage failure at all: the fault INJECTOR declining to
      inject more simultaneous corruption than the configured replication quorum tolerates. When
      this is non-zero, a sweep's effective fault rate is below its configured one — which is worth
      asserting on rather than discovering by instrumenting.
    - [entry_rejected] — a backend that cannot store an entry of this size
      ({!Riptide_storage.File_storage}'s one-aligned-data-slot limit). The only shape the original
      blanket catch actually documented.
    - [out_of_sequence] — the backend's own [wal_highest_op_number] is not [op_number - 1].
      Reachable by design, not a programming error: a log adoption refused partway through has
      already truncated and partially re-appended, so the durable log sits below this replica's own
      {!op_number} until a [StartView] repairs it. The gap reads back as corrupt, never absent, so
      the degradation is safe — which is exactly why it has to be visible rather than silently
      equated with the case above.
    - [eviction_blocked] — {!Riptide_storage.File_storage}'s [?may_evict] predicate declining to
      let this append overwrite an older entry the ring's owner still needs (subtask 3.7). {b One of
      two transient shapes} (the other is [storage_fault] below, added by Task 12): the call is
      well-formed, and the same [op_number] succeeds once the predicate relents, so this is
      backpressure rather than a defect. Flattening it into [entry_rejected] would say the exact
      opposite of what it means — that the entry can never be durable here — and would make this
      counter useless for the lag signal described above.
    - [storage_fault] (Task 12, audit-remediation Decision 3.3) — a REAL, narrowly-classified
      resource condition out of the backend: {!Out_of_memory} itself, or an
      {!Eio.Io}/bare {!Unix.Unix_error} wrapping exactly one of four errnos — [ENOSPC] (disk full),
      [EDQUOT] (quota exceeded — OCaml's [Unix.error] has no symbolic constructor for this, so it is
      matched as [EUNKNOWNERR 122], its value on every Linux this runs on), [EIO] (hardware I/O
      error), or [ENOMEM] (allocation failure at the syscall level). Before this bucket existed,
      none of these were [Invalid_argument] at all, so they matched nothing below and propagated
      straight out of {!durable_append} as an unhandled exception instead of being refused like
      every other kind of append failure — closing Storage-Important-1 (a disk filling up under a
      live {!Riptide_storage.File_storage} could kill the whole replica process).

      {b Deliberately narrow, not a blanket catch of [Eio.Io]/[Sys_error]/[Out_of_memory]:} a bare
      [Sys_error] (this module's storage layer never goes through an OCaml channel, so there is no
      real backend shape behind one — it is far more likely a genuine bug), any [Eio.Io] wrapping an
      errno other than the four above, or any [Eio.Io] wrapping a classified {!Eio.Fs.error} at all
      (e.g. [Not_found] — a missing file — or [Permission_denied] — permissions changed
      unexpectedly) all PROPAGATE instead, matching this same doc's own discrimination for
      [Invalid_argument] just below: an exception whose specific shape is not a recognized,
      documented refusal is a backend contract violation, not a storage refusal, and must crash
      loudly rather than be laundered into "safe to retry".

      {b One of two transient shapes} (see [eviction_blocked] above): an [ENOSPC]/[EDQUOT]/[EIO]/
      [ENOMEM]/[Out_of_memory] condition may clear, and a later retry of the same op_number may
      succeed — proven, not just asserted, by
      [test_vsr_replica_recovery.ml]'s "a storage_fault clears and the same op_number succeeds on
      retry" test (Task 12 re-review, Important-3), which drives a backend that fails the FIRST
      [wal_append] with a real [ENOSPC]-shaped [Eio.Io] and then delegates to
      {!Riptide_storage.Memory_storage} for every call after, and asserts the retried op is taken
      on with [storage_fault] staying at exactly 1 (not incremented again on the successful retry)
      — unlike [entry_rejected]'s permanent "too large for this backend".

      {b Weaker guarantee than the other four refusals, disclosed rather than hidden:} the other
      four are a clean no-op at the DURABLE-STORAGE level too (nothing written, nothing else
      disturbed — see {!Riptide_storage.File_storage}'s own [wal_append] doc). [storage_fault] is
      only guaranteed to be a clean no-op at THIS REPLICA's in-memory level.
      {!Riptide_storage.File_storage.wal_append} writes a slot's header, then its data, as two
      separate, non-atomic writes; a [storage_fault] raised between them can leave the ring slot's
      PRIOR occupant permanently unreadable ([Corrupt], per [wal_read]) — including an entry a
      [?may_evict] watermark had refused to let be evicted moments earlier, on an earlier call that
      relented before this one was attempted (the predicate, when it refuses, always fires before
      either write within one [wal_append] call, so it is never the occupant that specific call is
      in the middle of overwriting). This is a real, disclosed limitation of a two-write
      update, not a bug: whichever write order a backend uses, a fault between the two writes
      always risks losing the OTHER one.

    An [Invalid_argument] matching none of the first four is NOT counted and NOT swallowed: it
    propagates, because an unrecognized [Invalid_argument] out of a backend is a contract violation
    rather than a documented storage refusal. The same is true, by the identical reasoning, of any
    [Eio.Io]/[Sys_error]/[Unix.Unix_error]/[Out_of_memory] that does not match [storage_fault]'s
    narrow four-errno classification above. *)

(** {2 Test-support surface}

    Everything below exists purely to make [t] constructible into specific test scenarios; it is
    NOT part of the VSR protocol and no production caller should ever need it. Kept separate and
    clearly labeled per this plan's own Architecture note, rather than folded into the "real" API
    above. *)

val for_test_set_view_number : t -> int -> unit
(** [for_test_set_view_number t v] sets [t]'s [view_number] AND [last_normal_view] to [v]
    (previously, before fix-round finding M3 in `task-1-review.md`, it left [last_normal_view]
    behind at its Init value of [0] — see the two fields' own doc comments above, and
    [replica.ml]'s doc comment on this function, for why that was a real bug in the test-support
    surface itself: [status = Normal /\ last_normal_view <> view_number] is UNREACHABLE in the real
    protocol, TLC-confirmed across all 264,376 distinct reachable states of `spec/tla/VSR.tla`, so
    the old version silently built every calling test on top of a state the spec can never actually
    be in). [status] is left untouched (stays [Normal], its only value in this plan's scope).
    Exists because {!create} no longer takes a [primary_id] parameter — which replica id is primary
    is now always {!primary}, a pure function of [view_number] — so a test that needs a SPECIFIC
    replica id to play the primary role (the overwhelming majority of
    {!propose}/{!handle_message} tests, which are normal-case tests with no path to move
    [view_number] any other way in this plan's scope) has no way to get there other than this
    direct setter.

    {b [status = View_change] test states must use {!for_test_set_view} instead} — see that
    function's own doc comment for exactly why this one is CORRECT ONLY for [status = Normal].

    {b Convention this module's own test suite uses}: [for_test_set_view_number t 1] always makes
    replica id [1] the primary, for ANY [replica_count] — [Primary(1) = 1 + ((1-1) %
    replica_count) = 1 + (0 % replica_count) = 1] regardless of [replica_count]'s value — matching
    an earlier plan's own convention of conventionally using replica id [1] as "the" primary in
    hand-constructed tests, now achieved by view rather than by a configured field. *)

val for_test_set_view : t -> status:status -> view_number:int -> last_normal_view:int -> unit
(** [for_test_set_view t ~status ~view_number ~last_normal_view] sets all three fields directly and
    INDEPENDENTLY — unlike {!for_test_set_view_number}, it does NOT force
    [last_normal_view = view_number]. This is the test-support constructor
    {!for_test_set_view_number}'s own doc comment forward-references (originally written before
    this task existed, as [for_test_set_view : t -> status:... -> view_number:int ->
    last_normal_view:int -> unit]) — this is that helper, now actually built.

    {b Use this, never {!for_test_set_view_number}, to build a [View_change]-status test state} —
    {!for_test_set_view_number} is CORRECT ONLY for [status = Normal]: it force-syncs
    [last_normal_view] to [view_number], which is exactly right for [Normal] (the spec's own
    confirmed invariant, [status = "Normal" => last_normal_view = view_number], TLC-checked across
    VSR.tla's 264,376 reachable states — see that function's own doc comment) but exactly WRONG for
    [View_change]: a replica mid-view-change routinely has [last_normal_view <> view_number] (that
    divergence is the ENTIRE reason the field exists separately from [view_number] at all — VSR.tla
    31's own comment, "the paper's v', NOT derivable from rep_view_number"). Reusing
    {!for_test_set_view_number} to build a [View_change] test state would force-sync the two fields
    into a state [WinningDVC] (VSR.tla:248-255, Task 3's own scope) can never actually be exercised
    against in a real test — the exact mirror-image of the bug fix-round finding M3
    (`task-1-review.md`) fixed {!for_test_set_view_number} itself against for the [Normal] case.

    {b Does not touch [recv_svc]/[recv_dvc]/[sent_dvc]/[svc_count]} — {!create}'s own [Init] values
    (see also {!for_test_recv_dvc_senders}/{!for_test_recv_svc_senders}, which let a test observe
    the first two of those directly rather than inferring them from what gets sent)
    for those ([recv_svc]/[recv_dvc] empty, [sent_dvc = false], [svc_count = 0]) are what a replica
    freshly constructed and then moved via this setter still has; no separate SETTER exists for any
    of them, since every test reaches the states it needs by calling
    {!check_timeout}/{!handle_message} for real (see test_vsr_replica.ml) rather than by forcing
    those four fields directly. *)

val for_test_recv_dvc_senders : t -> int list
(** [for_test_recv_dvc_senders t] is the sorted list of replica ids currently holding an entry in
    [t]'s private [recv_dvc] accumulator (VSR.tla's [rep_recv_dvc[r]], VSR.tla:34) — i.e. the
    senders whose [DoViewChange] this replica has accepted, at most one per sender (see
    {!handle_message}'s [Do_view_change] arm for the sender-keying and first-wins rule).

    {b Read-only, and NOT filtered by [ValidDvc]} — it reports what the structure actually holds,
    including entries carried over from an earlier view, precisely so a test can assert on the two
    properties that are otherwise invisible from outside: that [ReceiveSV] deliberately leaves this
    accumulator populated (VSR.tla:304's own UNCHANGED), and that [TimerSendSVC]/[ReceiveHigherSVC]
    genuinely empty it (VSR.tla:169, 190). Without it, both are only observable second-hand,
    through whether some later message does or doesn't get sent — which is exactly the kind of
    indirect coverage an earlier task's review found had left a reset untested. *)

val for_test_recv_svc_senders : t -> int list
(** [for_test_recv_svc_senders t] is the sorted list of replica ids in [t]'s private [recv_svc] set
    (VSR.tla's [rep_recv_svc[r]], VSR.tla:33) — the [StartViewChange] senders accumulated for the
    current view-change episode, the set [SendDVC]'s own [Cardinality(...) >= f] threshold counts.
    Same rationale as {!for_test_recv_dvc_senders} above: it exists so a test can pin [ReceiveSV]'s
    deliberate non-reset (VSR.tla:304) and the episode resets directly. *)

val for_test_truncate_wal : t -> op_number:int -> unit
(** [for_test_truncate_wal t ~op_number] discards every durable WAL entry above [op_number] (and
    the matching in-memory entries), going through the same guarded path every protocol action
    uses.

    {b Raises [Invalid_argument "recovery: refusing to truncate below commit_number"]} when
    [op_number < commit_number t] — this plan's own Review Focus item: "VSR's own safety guarantee
    is that committed entries never disappear; this must be rejected by the caller ([replica.ml]),
    not silently accepted by the storage primitive". The boundary itself ([op_number =
    commit_number t]) is accepted: discarding the UNCOMMITTED suffix is exactly what a legal
    view-change completion does.

    Test-support, not protocol. No VSR action truncates the WAL without writing the canonical log
    back in the same step, so this is the only caller for which the guard takes this simple form —
    a log ADOPTION ([SendSV]/[ReceiveSV]) is checked against the length the durable log will have
    once the adoption finishes, which is what lets it repair a corrupt slot BELOW the commit point
    by rewriting it (see the implementation's own [truncate_wal]). *)

val for_test_wal_read : t -> op_number:int -> Riptide.Value.value option
(** [for_test_wal_read t ~op_number] is what this replica can actually READ back off its durable
    storage at [op_number] — [None] for a slot that is beyond the log, or present but unreadable
    ([VSR.tla]'s ["absent"] and ["corrupt"] respectively, which this accessor deliberately does not
    distinguish: telling them apart is a protocol decision, made inside this module against the
    durable op-number, not something a test should be able to shortcut).

    Test-support, not protocol. It exists so a test can assert on DURABILITY directly — that an
    entry really reached the WAL, or that a truncation really removed it — rather than inferring it
    from {!entries}, which is the in-memory copy and would pass even if nothing were ever written
    through to storage at all. *)
