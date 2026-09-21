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

    {b Still out of scope}, as for `spec/tla/VSR.tla` itself (see `spec/tla/README.md`):
    state-transfer, storage-fault-aware recovery, crash modeling, reconfiguration, the client
    table, and COMMIT messages. Two disclosed, liveness-only simplifications are inherited
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
(** One replica's mutable state: its log, op-number (tracked implicitly as the log's own length —
    see {!op_number}), commit-number, view-change status/view-number/last-normal-view (see the
    top-level scope note above for what is and isn't yet wired up), and (primary-only) per-peer
    acknowledgment high-water marks. *)

val create : my_id:int -> replica_count:int -> svc_limit:int -> send:(to_:int -> string -> unit) -> t
(** [create ~my_id ~replica_count ~svc_limit ~send] is a fresh replica matching VSR.tla's [Init]
    (VSR.tla:71-84) restricted to this replica [my_id]: empty log, [op_number = 0],
    [commit_number = 0], [status = Normal], [view_number = 0], [last_normal_view = 0],
    [recv_svc]/[recv_dvc] empty, [sent_dvc = false], [svc_count = 0], no peer acknowledgments
    recorded yet.

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
    {!propose}/{!handle_message} too. *)

val primary : t -> int
(** [primary t] is VSR.tla's own [Primary(View(r)) == 1 + ((View(r)-1) % ReplicaCount)]
    (VSR.tla:18) evaluated against [t]'s current {!view_number} — a pure, computed function of
    state, never a stored field. See this module's own top-level scope note for the Euclidean-vs-
    truncating-modulo trap this implementation is normalized against, and for why [view_number =
    0]'s primary is [replica_count], not [1]. *)

val is_primary : t -> bool
(** [is_primary t] is VSR.tla's own [r = Primary(View(r))] test — exactly [t.my_id = primary t]. *)

val op_number : t -> int
(** [op_number t] is VSR.tla's [rep_op_number[r]] (VSR.tla:24). Always equals the number of
    entries in this replica's log — VSR.tla's own [LogLengthMatchesOpNumber] invariant
    (VSR.tla:337-338) — because this module tracks op-number AS the log's length ({!
    Riptide_vsr.Replica_log.length}) rather than as separate mutable state kept in lockstep by
    hand, which makes that invariant true by construction instead of something a caller (or a
    future refactor) could accidentally violate. *)

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
    value. *)

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
(** [check_timeout t] is VSR.tla's [TimerSendSVC] (VSR.tla:161-174) — the entry point a caller
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

val handle_message : t -> string -> unit
(** [handle_message t bytes] decodes [bytes] via {!Riptide_vsr.Message.decode} and dispatches:

    - A [Prepare] message drives VSR.tla's [ReceivePrepareMsg] (VSR.tla:110-123): a backup-side
      handler ([IsNormalBackup(r)] == [status[r] = "Normal" /\ Primary(View(r)) # r], VSR.tla:49 —
      a no-op if [status t <> Normal] OR if [t] IS the primary; an earlier, normal-case-only plan's
      version only checked the primary half), gated on [m.view = view_number t] and, per VSR.tla's
      own strict-order guard [rep_op_number[r] + 1 = m.n] (VSR.tla:115), on the message's [n]
      being exactly [op_number t + 1]. {b An out-of-order [Prepare] (too high, too low, or a gap)
      is silently dropped} — log unchanged, no [Prepare_ok] sent, no exception raised to the
      caller — exactly matching VSR.tla's own behavior of simply not enabling this action for a
      mismatched [n]: there is no buffering, reordering, or retry logic anywhere in this module's
      (or the underlying spec's) scope. {b This is a real, disclosed liveness gap}, not a defect: a
      backup that misses one [Prepare] has no way to catch up in this module's scope (no
      COMMIT-message resend, no state-transfer, no retry — those are explicitly out of scope for
      `spec/tla/VSR.tla` itself, per `spec/tla/README.md`). On success: appends [m.v] at [m.n],
      advances [commit_number] to [m.k] if higher AND if [m.k <= op_number t] (i.e. [<= m.n],
      since [op_number t] has just become [m.n]) — never regresses it (VSR.tla:118's own [IF m.k >
      @ THEN m.k ELSE @]), and never lets it exceed what this replica's own log actually contains,
      even for a [Prepare] whose [k] a corrupted/forged network delivery has pushed past [n]
      (VSR.tla's own [m.k < m.n] precondition, VSR.tla:106-109, holds for every [Prepare] the
      TLA+ model itself can produce, but rather than trust it this module enforces its own
      explicit bound, [m.k <= m.n] — deliberately one step wider than that precondition, which
      would exclude [m.k = m.n]; see {!commit_number}'s own doc comment and [replica.ml]'s comment
      at the bound itself for why the extra step is a harmless defense-in-depth margin here, and
      why tightening it is the safer direction once view-change lands) — then unicasts
      [Prepare_ok{view=view_number t; n=m.n; i=my_id}] back to {!primary}'s current value (NOT a
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
      already in is accepted and re-applied; only a strictly lower [m.v] is dropped. Effect: adopts
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
      with [m.n < rep_commit_number[r]]). Note [Start_view] carries no [i] field at all (neither does
      the spec's own record literal), so there is no sender to range-check.

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
