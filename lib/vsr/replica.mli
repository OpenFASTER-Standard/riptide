(** A single VSR replica's normal-case state and message handling — `spec/tla/VSR.tla`'s
    [ReceiveClientRequest], [ReceivePrepareMsg], [ReceivePrepareOkMsg], and [PrimaryExecuteOp]
    (VSR.tla:91-155), implemented against a FIXED primary.

    {b Scope}: normal-case operation only. View-change ([TimerSendSVC] through [ReceiveSV],
    VSR.tla:161-305) is out of scope for this module — [primary_id] is fixed at {!create} time
    and never changes, matching VSR.tla's own incremental history (its normal-case actions were
    modeled with a fixed [Primary(0)] before view-change was added). A [Start_view_change] /
    [Do_view_change] / [Start_view] message reaching {!handle_message} is silently ignored, not
    an error — a later plan adds real handling once view-change exists.

    {b View number}: every message this module sends or accepts carries view [0] (VSR.tla's own
    [View(r)] is [rep_view_number[r]], which starts at [0] at [Init] and this module never
    changes it, matching the fixed-primary scope above). {!handle_message} enforces VSR.tla's own
    [m.view = View(r)] guard by dropping any message whose [view]/[view] field isn't exactly [0]
    — a real guard, not a no-op, so this module's message-level behavior stays faithful to the
    spec even though the value never varies within this plan's scope.

    {b Replica identity}: replica ids are [1..replica_count], matching VSR.tla's own
    [replicas == 1..ReplicaCount] and [Primary(v) == 1 + ((v-1) % ReplicaCount)] (VSR.tla:15-18).
    This module does not itself implement [Primary(v)] — since the primary never changes within
    this plan's scope, {!create}'s caller simply passes the id that formula would have produced
    for view 0 ([primary_id = 1] for the fixed view-0 case, i.e. [Primary(0) = 1 + ((0-1) mod
    ReplicaCount)]; in practice callers just pass [1] as VSR.cfg's own convention does — see
    [replica.ml] for a note on why [Primary(0) = 1] specifically).

    {b [dest] and message delivery}: {!Riptide_vsr.Message.t} deliberately omits the TLA+ spec's
    own [dest] field (see [message.mli]) because the transport layer's own destination argument
    already carries it. Consequently VSR.tla's [ReceivableMsg(m, type, r)]'s own [m.dest = r]
    conjunct (VSR.tla:68) needs no separate check here: by construction, a message only ever
    reaches a replica's {!handle_message} by way of that replica's own transport handle, which
    is exactly what "dest = r" meant in the TLA+ message-bag model. *)

type t
(** One replica's mutable normal-case state: its log, op-number (tracked implicitly as the log's
    own length — see {!op_number}), commit-number, and (primary-only) per-peer acknowledgment
    high-water marks. *)

val create :
  my_id:int -> replica_count:int -> primary_id:int -> send:(to_:int -> string -> unit) -> t
(** [create ~my_id ~replica_count ~primary_id ~send] is a fresh replica matching VSR.tla's [Init]
    (VSR.tla:71-84) restricted to this replica [my_id]: empty log, [op_number = 0],
    [commit_number = 0], no peer acknowledgments recorded yet.

    [primary_id] is FIXED for this replica's entire lifetime — see this module's own top-level
    scope note; there is no way to change it after {!create} (a later, view-change-aware plan
    will need to restructure this).

    [send] is a closure over some transport handle's own [send : t -> to_:int -> string -> unit]
    (see {!Riptide_transport.Transport_intf.S.send}) with the handle itself and [~to_]'s type
    already applied down to just [to_:int -> string -> unit] — deliberately NOT a direct
    dependency on [Transport_intf.S] or [lib/transport] at all (this library's own [dune] has no
    such dependency; see this plan's own design notes), so this module stays usable against any
    future transport implementation that can produce a closure of this shape. [send] is called
    synchronously, inline, from within {!propose} and {!handle_message} — never queued or
    deferred — so a caller supplying a closure that itself blocks will block the caller of
    {!propose}/{!handle_message} too. *)

val is_primary : t -> bool
(** [is_primary t] is [Primary(View(t)) = t] — whether this replica IS the (fixed, for this
    module's scope) primary, i.e. [my_id = primary_id] as passed to {!create}. *)

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
    actions). *)

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

    {b No-op, not an error, if [t] is not the primary} (["not (is_primary t)"]): this mirrors
    VSR.tla's own [IsNormalPrimary(r)] guard (VSR.tla:48, conjoined into [ReceiveClientRequest]
    at VSR.tla:93) — when a guard in the TLA+ model doesn't hold, the action simply isn't enabled
    and nothing happens; there is no "reject with an error" step anywhere in the spec for this
    case for {!handle_message} to mirror ([Malformed_message]/[Out_of_order_append] are a
    different case — see {!handle_message} — genuine adversarial/network conditions the spec
    deliberately doesn't model at all, not a guard failure within the model). Use {!is_primary}
    first if the caller needs to distinguish "was rejected because I'm not the primary" from
    "was accepted."

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
    [Prepare{view=0; n=op_number t + 1; v; k=commit_number t}] (VSR.tla's [Broadcast], VSR.tla:64,
    98-99) to every OTHER replica [1..replica_count] (i.e. every id in that range except this
    replica's own [my_id] — VSR.tla's [BroadcastFunc]'s own [replicas \ {source}], VSR.tla:56),
    via [create]'s [send] closure, once per destination. *)

val handle_message : t -> string -> unit
(** [handle_message t bytes] decodes [bytes] via {!Riptide_vsr.Message.decode} and dispatches:

    - A [Prepare] message drives VSR.tla's [ReceivePrepareMsg] (VSR.tla:110-123): a backup-side
      handler ([IsNormalBackup(r)], VSR.tla:49 — a no-op if [t] IS the primary), gated on
      [m.view = 0] and, per VSR.tla's own strict-order guard [rep_op_number[r] + 1 = m.n]
      (VSR.tla:115), on the message's [n] being exactly [op_number t + 1]. {b An out-of-order
      [Prepare] (too high, too low, or a gap) is silently dropped} — log unchanged, no
      [Prepare_ok] sent, no exception raised to the caller — exactly matching VSR.tla's own
      behavior of simply not enabling this action for a mismatched [n]: there is no buffering,
      reordering, or retry logic anywhere in this module's (or the underlying spec's) scope. {b
      This is a real, disclosed liveness gap}, not a defect: a backup that misses one [Prepare]
      has no way to catch up in this module's scope (no COMMIT-message resend, no state-transfer,
      no retry — those are explicitly out of scope for `spec/tla/VSR.tla` itself, per
      `spec/tla/README.md`). On success: appends [m.v] at [m.n], advances [commit_number] to
      [m.k] if higher (never regresses it — VSR.tla:118's own [IF m.k > @ THEN m.k ELSE @]), and
      unicasts [Prepare_ok{view=0; n=m.n; i=my_id}] back to the primary.
    - A [Prepare_ok] message drives VSR.tla's [ReceivePrepareOkMsg] (VSR.tla:126-136): a
      primary-side handler ([IsNormalPrimary(r)] — a no-op if [t] is not the primary), gated on
      [m.view = 0]. Updates this replica's tracked high-water mark for peer [m.i] to [m.n], but
      ONLY if higher than what was already recorded (VSR.tla:131-132's own [IF m.n > @ THEN m.n
      ELSE @]) — cumulative, not per-op, per VSR.tla's own §1.5 point 2 comment (VSR.tla:125).
      Then internally drives VSR.tla's [IsCommitted]/[PrimaryExecuteOp] (VSR.tla:139-155): this is
      NOT a separate externally-triggered action in the TLA+ model (nothing but time passing
      enables it) — it becomes newly enabled only when [rep_peer_op_number] changes, which only
      [ReceivePrepareOkMsg] does, so it is driven directly from here, exactly once per
      [Prepare_ok] processed, per this module's own design (matching the containing plan's
      Architecture notes). The advance is applied INCREMENTALLY: starting from
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
      module's scope is normal-case only; see this file's own top-level comment) — NOT an error,
      since a real message stream will carry these once a later plan adds view-change, and this
      replica must not crash on a message type it doesn't yet handle.
    - Any input that fails to decode (raises {!Riptide_vsr.Message.Malformed_message}) is treated
      the same as an out-of-order [Prepare]: silently dropped, no exception propagates to the
      caller. A real network provides no payload integrity ({!Riptide_transport.Transport_intf.S}'s
      own documented guarantee), and this replica must not crash when it is handed garbage. *)
