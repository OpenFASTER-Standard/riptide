(** A single replica's `rep_log[r]` (`spec/tla/VSR.tla`'s own `VARIABLES` comment: [[replica ->
    Seq(Values)]]) — the three operations VSR's own actions actually perform on that sequence,
    and nothing else:

    - {!append}: [ReceiveClientRequest]/[ReceivePrepareMsg]'s [Append(@, v)] /
      [Append(@, m.v)], but strict about position — VSR.tla's own guard,
      [rep_op_number[r] + 1 = m.n], is enforced here rather than left to a caller's separate
      bookkeeping discipline.
    - {!get}: the indexed reads [rep_log[r][op_number]] performed by [PrimaryExecuteOp]
      ([rep_log[r][next]]) and the [NoLogDivergence] invariant.
    - {!replace_with}: the wholesale overwrites [rep_log' = [rep_log EXCEPT ![r] = winner.log]]
      ([SendSV]) and [rep_log' = [rep_log EXCEPT ![r] = m.log]] ([ReceiveSV]) perform when a
      view change completes, discarding whatever was in the log before.

    Deliberately simpler than {!Riptide.Log}'s own [log] type: no hash-chaining, no
    {!Riptide.Envelope} wrapping, no [actor]/[causation]/[correlation] metadata. VSR's
    [rep_log[r]] is [Seq(Values)] — a plain sequence of values, one layer below where
    {!Riptide.Log}'s envelope metadata belongs. See this plan's own research-grounding notes for
    why {!Riptide.Log} itself doesn't fit here: it always appends at its own internally-tracked
    tail with no caller-specified position (so it can't reject an out-of-order append the way
    this module's {!append} does), has no indexed read, and has no truncate/replace operation
    (only ever-growing append) — none of which VSR's [rep_log[r]] usage matches.

    Mutable, matching {!Riptide.Log}'s own established convention for this codebase's
    mutable-log-type modules (a record with a [mutable] entries field, stored newest-first
    internally, plus a [t] left abstract in this [.mli]) rather than a persistent/functional
    log. *)

type t

val create : unit -> t
(** A fresh, empty log — matches [rep_log[r]] at [Init] ([<<>>], the empty sequence). *)

exception Out_of_order_append of { expected : int; got : int }
(** Raised by {!append} when [~op_number] is not exactly [expected] (the log's current
    {!length} plus one) — VSR.tla's own [rep_op_number[r] + 1 = m.n] guard, made structural
    here rather than a precondition callers must separately re-check. [got] is the [~op_number]
    the caller actually passed; this covers all three shapes the task brief calls out as
    rejected: too high, too low (including a duplicate/already-applied op-number), and a gap. *)

val append : t -> op_number:int -> Riptide.Value.value -> unit
(** [append t ~op_number v] appends [v] as entry number [op_number] (1-indexed), the ordered
    append VSR.tla's [ReceiveClientRequest]/[ReceivePrepareMsg] both perform via [Append(@, v)].
    Raises {!Out_of_order_append} unless [op_number] is exactly [length t + 1] — this is the
    ONLY way to grow the log (see {!replace_with} for wholesale replacement instead). *)

val get : t -> op_number:int -> Riptide.Value.value option
(** [get t ~op_number] is [rep_log[r][op_number]] from VSR.tla, 1-indexed exactly as the spec's
    own [Seq] indexing convention — op-number 1 is the first entry appended. Returns [None] for
    any out-of-range [op_number] (0, negative, or beyond {!length}) rather than raising: unlike
    {!append}'s out-of-order rejection (a genuine protocol violation worth surfacing loudly),
    reading past the end of a log that another replica has already advanced further than this
    one is an entirely ordinary, expected condition in a replicated system, not an error. *)

val replace_with : t -> Riptide.Value.value list -> unit
(** [replace_with t log] discards every entry currently in [t] and replaces them wholesale with
    [log] (given oldest-first, i.e. [log.(0)] becomes op-number 1 — the same order {!to_list}
    returns and the same order a [Value.Sequence] carried over the wire in a
    [Do_view_change]/[Start_view] message ({!Riptide_vsr.Message.t}) is stored in). Matches
    [rep_log' = [rep_log EXCEPT ![r] = winner.log]] ([SendSV]) / [rep_log' = [rep_log EXCEPT
    ![r] = m.log]] ([ReceiveSV]) in VSR.tla — both view-change-completion actions replace a
    replica's ENTIRE log in one step, not by hand-replaying an append per entry. After this
    call, {!length} equals [List.length log] and {!get t ~op_number:1} through
    {!get t ~op_number:(List.length log)} return [log]'s entries in order — immediately, with
    no further caller-side bookkeeping. *)

val length : t -> int
(** The number of entries currently in the log. Always equals the number of entries actually
    present, by this module's own construction (every {!append} grows it by exactly one, every
    {!replace_with} resets it to the replacement's length) — this is VSR.tla's own
    [LogLengthMatchesOpNumber] invariant ([Len(rep_log[r]) = rep_op_number[r]]), which this
    module makes true by construction rather than leaving it to a caller to maintain
    [rep_op_number] in lockstep by hand. (Note: this module tracks only the log's own length,
    not [rep_op_number] itself — a real replica implementation, built on this module in a later
    plan, still owns [rep_op_number] as separate per-replica state, per VSR.tla's [VARIABLES]
    list; this invariant just says the two must always agree once that's wired up.) *)

val to_list : t -> Riptide.Value.value list
(** The log's entries in append order (oldest first, i.e. op-number 1 first) — the same order
    {!replace_with} expects its argument in, and the order a [Do_view_change]/[Start_view]
    message's own [log] field ({!Riptide_vsr.Message.t}) should be built from when sending this
    replica's log over the wire. *)
