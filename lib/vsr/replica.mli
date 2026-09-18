(** A single VSR replica's state and message handling — `spec/tla/VSR.tla`'s
    [ReceiveClientRequest], [ReceivePrepareMsg], [ReceivePrepareOkMsg], and [PrimaryExecuteOp]
    (VSR.tla:91-155), generalized to a real, mutable [status]/[view_number] rather than a fixed
    primary.

    {b Scope}: this module implements the normal-case actions above against the GENERAL form of
    their guards ([IsNormalPrimary(r) == status[r] = "Normal" /\ Primary(View(r)) = r] and
    [IsNormalBackup(r) == status[r] = "Normal" /\ Primary(View(r)) # r], VSR.tla:48-49) — not the
    fixed-primary/fixed-view=0 simplification an earlier plan built these against. View-change
    itself ([TimerSendSVC] through [ReceiveSV], VSR.tla:161-305) is still out of scope for this
    module's BEHAVIOR — nothing in this module ever moves [status] to [View_change] or advances
    [view_number] — but the STATE those actions need ([status], [view_number],
    [last_normal_view], [recv_svc], [recv_dvc], [sent_dvc], [svc_count]) already lives on [t], so
    a later plan implementing them needs no further restructuring of [t] itself. A
    [Start_view_change] / [Do_view_change] / [Start_view] message reaching {!handle_message} is
    silently ignored, not an error — a later plan adds real handling once view-change exists.

    {b View number}: {!handle_message} enforces VSR.tla's own [m.view = View(r)] guard by
    dropping any in-scope message — a [Prepare] or a [Prepare_ok], the two types that carry a
    [view] field — whose [view] isn't exactly {!view_number}'s current value. (The out-of-scope
    view-change types name their own field [v], not [view]; they are dropped wholesale, without a
    view check, per the scope note above.)

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
    [StartViewOnTimerLimit] (VSR.tla:13) — stored on [t] now, per this plan's own Architecture, but
    not yet READ by anything in this plan's scope (a later plan's [check_timeout] is its first
    reader), though it IS validated at {!create} time (see below) — [svc_limit] is the parameter
    that structurally replaced the removed [primary_id] in this signature, and its own range needs
    the same kind of cheap sanity check [primary_id] used to get.

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
    network-corrupted/adversarial [Prepare]}, not merely for well-formed input: VSR.tla:118's own
    [rep_commit_number' = IF m.k > @ THEN m.k ELSE @] is safe in the TLA+ model only because every
    [Prepare] there is produced by [ReceiveClientRequest] itself, which guarantees [m.k < m.n]
    (VSR.tla:106-109's own comment) — a precondition that does not hold for a [Prepare] decoded
    off {!Riptide_transport.Transport_intf.S}'s own "no payload integrity" wire. {!handle_message}
    bounds it explicitly by REJECTING (not capping/clamping) a [Prepare]'s [k] once it
    would exceed [op_number t] (this replica's own log length, which the [Prepare] being
    processed has just extended to [m.n]) — [commit_number] is left at its prior, legitimately-
    established value rather than substituted with a different one.

    {b Only that one field's effect is discarded — the message itself is NOT treated as suspect}:
    [m.v] is still appended at [m.n] and a [Prepare_ok{n = m.n}] is still unicast back to the
    primary, exactly as for any in-order [Prepare]. Dropping the whole message instead would open
    a gap in this replica's log that nothing in this plan's scope (no state transfer, no retry)
    could ever repair. Rejecting rather than CLAMPING the [k] update is the real point of the
    design: a clamp would target [op_number t], i.e. the maximum legal value, so a single
    corrupted integer would let a backup declare its entire log committed — invariant-preserving
    and still completely wrong. See {!handle_message}'s own doc comment below for the exact bound, and the
    analogous, independently-established bound on a [Prepare_ok]'s own [n] field (a genuine ack
    can never claim to have acked an op-number this primary hasn't itself assigned). *)

val view_number : t -> int
(** [view_number t] is VSR.tla's [rep_view_number[r]] (VSR.tla:30), i.e. [View(r)]. Starts at [0]
    (VSR.tla's own [Init]) and, within this plan's scope, only changes via
    {!for_test_set_view_number} — nothing in this module yet implements any REAL action that
    advances it (view-change is a later plan's scope; see this module's own top-level note).
    Exposed read-only, the same way {!op_number}/{!commit_number} are, since it is genuine protocol
    state, not a test-only concern. *)

val last_normal_view : t -> int
(** [last_normal_view t] is VSR.tla's [rep_last_normal_view[r]] (VSR.tla:31) — the paper's own
    [v'], deliberately NOT derivable from {!view_number} in general (see [replica.ml]'s own doc
    comment on the field). Within this plan's scope it only ever changes in lockstep with
    {!view_number}, via {!for_test_set_view_number} — see that function's own doc comment for why
    keeping the two synchronized is the only choice consistent with a genuine spec invariant,
    confirmed by TLC: [status = "Normal" => last_normal_view = view_number] holds in every one of
    VSR.tla's 264,376 distinct reachable states. Exposed read-only for the same reason
    {!view_number} is: genuine protocol state a caller (in particular, a future Task 2/3 test
    asserting this invariant, or [WinningDVC]'s own eventual consumer) may need to inspect. *)

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
    rejected because I'm not the primary" from "was accepted" — note this does NOT by itself
    distinguish the [status <> Normal] rejection case; a caller needing that distinction too has
    no accessor for [status] in this plan's scope (nothing in this module can move [status] away
    from [Normal] yet — see the top-level scope note).

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
    - A [Start_view_change], [Do_view_change], or [Start_view] message is silently ignored (this
      module doesn't yet implement view-change's own actions; see this file's own top-level
      comment) — NOT an error, since a real message stream will carry these once a later plan adds
      view-change, and this replica must not crash on a message type it doesn't yet handle.
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

    {b If a future test genuinely needs [view_number] and [last_normal_view] to differ} (e.g. to
    construct a mid-view-change state, once {!create}/a future setter can put [status] into
    [View_change]), it should get its OWN, separate, explicitly-named test-support constructor
    (e.g. [for_test_set_view : t -> status:... -> view_number:int -> last_normal_view:int -> unit])
    rather than repurposing this one — keeping this one's default reachable is the point.

    {b Convention this module's own test suite uses}: [for_test_set_view_number t 1] always makes
    replica id [1] the primary, for ANY [replica_count] — [Primary(1) = 1 + ((1-1) %
    replica_count) = 1 + (0 % replica_count) = 1] regardless of [replica_count]'s value — matching
    an earlier plan's own convention of conventionally using replica id [1] as "the" primary in
    hand-constructed tests, now achieved by view rather than by a configured field. *)
