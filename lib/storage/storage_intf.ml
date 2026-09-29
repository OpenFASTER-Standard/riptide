(** Signature every conforming storage backend implements — mirrors
    [Riptide_transport.Transport_intf.S]'s minimalism: an abstract [t] plus
    the operations callers need, nothing about how a backend is opened or
    closed (each implementation has its own concrete [create]). *)
module type S = sig
  type t

  (** [wal_append t ~op_number bytes] durably appends one WAL entry.
      [op_number] must be exactly one greater than [wal_highest_op_number t]
      (matching {!Riptide_vsr.Replica_log.append}'s own out-of-order guard) —
      implementations raise [Invalid_argument] otherwise. Returns only after
      the write is durable (survives a process crash immediately after).

      {b Which exceptions may legitimately escape, and what each means to a
      caller} (Task 12, audit-remediation Decision 3.3 — this clause is new;
      before it, this contract said nothing about non-[Invalid_argument]
      failures at all, and one going uncaught up through
      {!Riptide_vsr.Replica.durable_append} could kill the whole replica
      process): a conforming implementation may also raise
      - [Eio.Io] wrapping a {!Unix.Unix_error}, or a bare {!Unix.Unix_error}
        directly (a backend not built on Eio), for a REAL, transient
        resource condition — [ENOSPC], [EDQUOT], [EIO], or [ENOMEM] — or
      - [Out_of_memory] itself,

      and {!Riptide_vsr.Replica.durable_append} classifies exactly those
      shapes as its own [storage_fault] refusal (declines to acknowledge,
      counts it, does not crash) rather than an unrecognized exception. Any
      OTHER exception shape — a bare [Sys_error], an [Eio.Io]/[Unix.Unix_error]
      with a different errno, or an [Invalid_argument] not matching one of
      the four documented guard-failure messages this interface's other
      implementations use — is NOT part of this contract and propagates as a
      backend contract violation. A future implementation must not raise
      anything outside this list to signal a refusal it wants a caller to be
      able to retry; there is currently no mechanism for widening the
      recognized set other than updating {!Riptide_vsr.Replica} itself. *)
  val wal_append : t -> op_number:int -> string -> unit

  (** [wal_read t ~op_number] is [None] if no entry was ever written at
      [op_number], or if the entry stored there is corrupt (checksum
      mismatch) — a reader cannot tell those two cases apart from this
      signature alone, by design: telling them apart is exactly what the
      recovery protocol in Task 7 exists to do, using cross-replica
      evidence this single-node signature has no access to. *)
  val wal_read : t -> op_number:int -> string option

  (** [wal_truncate_after t ~op_number] discards every WAL entry with a
      higher op-number. No-op if [op_number >= wal_highest_op_number t].

      {b The discard is DURABLE}, in exactly the sense [wal_append] is:
      reopening the same backend afterwards must not resurrect a discarded
      entry, and must not report a [wal_highest_op_number] above
      [op_number]. Stated here as a contract clause because it was a real
      divergence between two conforming implementations (final-review
      finding I3): [Memory_storage] physically deleted while [File_storage]
      only lowered an in-memory counter, leaving the discarded entries'
      headers and data on disk for its own recovery scan to find again.
      [test/test_storage_shared.ml]'s conformance suite structurally cannot
      check this — it has no reopen case, because [Memory_storage] has no
      restart semantics to have one against — so the clause is pinned by
      [test/test_file_storage.ml]'s own reopen-after-truncate tests instead.
      A backend that cannot honour it must say so at its own [create], not
      leave callers to discover it after a crash. *)
  val wal_truncate_after : t -> op_number:int -> unit

  (** 0 if the WAL is empty. {b The STRICT reading}: the highest op-number this backend can
      currently hand back through {!wal_read} in full (header and data both verifying, where a
      backend has such a distinction). See {!wal_highest_durable_op_number} for the other,
      deliberately different reading, and why both exist. *)
  val wal_highest_op_number : t -> int

  (** [wal_highest_durable_op_number t] is the highest op-number this backend has any durable
      evidence it ever accepted an entry for -- {b whether or not that entry can still be read
      back}. Always [>= wal_highest_op_number t]; equal for a backend with no partial-write failure
      mode of its own (e.g. {!Riptide_storage.Memory_storage}, whose two readings coincide by
      construction), and strictly greater for {!Riptide_storage.File_storage} exactly when a slot's
      HEADER survived a crash but its DATA did not.

      {b Why this is a second accessor rather than a stricter/looser reading of the one above}
      (Task 13 re-review finding 2). The two readings are not interchangeable, and each caller needs
      a specific one:
      - A caller asking "can I READ op [o]?" -- {!Riptide_vsr.Replica}'s own [slot_state], and
        {!wal_append}'s own [op_number = wal_highest_op_number t + 1] sequencing guard -- needs the
        STRICT one.
      - A caller asking "might this backend still be HOLDING something at op [o]?" needs this one,
        and getting it wrong is a safety bug rather than an inefficiency. VSR's nack rule
        ([CanNack], VSR.tla:157) lets a replica prove an op ABSENT purely from its own op-number
        being lower, and [StorageWellFormed] (VSR.tla:742-745) is what makes that sound: a durably
        written slot must never read back absent. A backend that under-reports here therefore makes
        its replica prove absent ops it really did durably hold, which is precisely the
        "corrupt -> absent" one-word mutation spec/tla/VSR.tla:111-150 records TLC refuting against
        [NoCommittedOpProvablyAbsent].

      The three callers that must use THIS one, all for that reason: {!Riptide_vsr.Replica.restart}'s
      fail-stop guard and {!Riptide_vsr.Replica.create}'s
      backend-is-not-virgin guard (both of which decide whether a backend is EMPTY -- and a backend
      holding one header-only slot is not), and {!superblock_rebuild_from_wal}'s own [op_number]
      derivation. *)
  val wal_highest_durable_op_number : t -> int

  (** Durably overwrites the single superblock record. *)
  val superblock_write : t -> string -> unit

  (** [None] if no superblock was ever written, or if fewer than a majority
      of copies agree (see Task 3). *)
  val superblock_read : t -> string option

  (** [superblock_rebuild_from_wal t ~view_number ~last_normal_view ~commit_number] durably writes a
      fresh superblock over a lost one, combining the ONE field this backend can determine for
      itself ([op_number], from its own WAL) with the three an operator must supply. It is the
      repair action for the state {!Riptide_vsr.Replica.restart}'s own fail-stop guard exists to
      catch (audit-remediation Task 13): a superblock unreadable (fewer than a majority of copies
      verify and agree, or the record does not decode) over a WAL that is otherwise completely
      intact. A torn superblock write never touches the WAL itself, so the durable log is still all
      there -- only the small, separately-stored record a restart needs before it can trust the rest
      is gone.

      {b READ THIS BEFORE CALLING IT. This is a tool of last resort operated by a human with
      out-of-band knowledge, NOT a safe automatic self-heal, and it cannot be made into one.} The
      three supplied values must be THIS REPLICA'S OWN real prior durable view/commit state -- the
      exact triple its own superblock held immediately before the write that tore it. Supplying
      values this storage layer could have invented on its own -- in particular ZEROS, which is what
      the first cut of this function silently wrote -- converts VSR's own safe permanent-stall
      failure mode into SILENT, CLUSTER-WIDE LOSS of a committed, client-acknowledged operation.

      {b RETRACTION: DO NOT READ THESE VALUES OFF A LIVE PEER'S CURRENT STATE.} An earlier version
      of this comment (and of {!Riptide_vsr.Replica.restart}'s own message, and of
      {!Riptide_dst.Cluster}'s [superblock_repair]) instructed an operator to obtain them "from a
      live, trusted, surviving peer of the same cluster -- ITS [view_number], ITS
      [last_normal_view]". {b That instruction is withdrawn: it was actively wrong, not merely
      risky-if-misapplied}, and following it destroys committed data in its own right by a mechanism
      that is the exact OPPOSITE of the one the zeros trace below describes. A peer's CURRENT
      [last_normal_view] equals this replica's true [last_normal_view] only if this replica never
      fell behind that peer on view transitions -- which is precisely what cannot be established
      from outside once this replica's own superblock, the only record of it, is gone.

      {b THE TWO DIRECTIONS, both catastrophic, by different mechanisms.} Each is a concrete trace
      pinned by a running test in [test/test_vsr_replica_recovery.ml]; neither is an argued
      possibility.

      TOO LOW (under-claiming) -- {b this replica's own uniquely-held committed data is truncated}
      ([test_a_rebuild_with_zeroed_values_destroys_a_committed_op_through_a_view_change],
      [test_a_rebuild_with_only_last_normal_view_wrong_still_destroys_it], and the fixed arm
      [test_a_rebuild_with_correct_values_preserves_that_same_committed_op] -- three runs of ONE
      scenario function, differing in nothing but these three arguments):
      - A 3-replica cluster commits and acknowledges op 1 in view 1. Replicas 1 and 2 hold it
        durably; replica 3 never saw it. Replica 1 is then lost for good, and replica 2 comes back
        from a crash with a torn superblock -- so the ONLY surviving durable copy of the
        acknowledged op is replica 2's.
      - Rebuilt with [last_normal_view = 0], replica 2's DoViewChange loses view-change log
        selection to replica 3's (which honestly reports [last_normal_view = 1] over an EMPTY log),
        because [WinningDVC] (VSR.tla:432) picks the highest [last_normal_view]. The new view's log
        is reconstructed from the winner, i.e. as empty, and the committed op is truncated on every
        replica at once with no error anywhere.
      - Rebuilt with the true [last_normal_view = 1], the two DVCs tie on [last_normal_view] and
        selection falls to the longer log -- replica 2's -- so the committed op survives, is
        re-replicated, and the cluster continues correctly.

      TOO HIGH (over-claiming) -- {b the CLUSTER's already-committed data is silently REPLACED by
      this replica's stale values}, which is strictly worse than the truncation above: the cluster
      does not lose an acknowledged operation, it adopts a DIFFERENT one in its place and reports it
      committed. This is exactly what copying a live peer's current values produces
      ([test_a_rebuild_copying_a_live_peers_current_values_replaces_committed_data] and its fixed
      counterpart [test_a_rebuild_with_this_replicas_own_true_prior_state_preserves_committed_data]
      -- again one scenario function, two integer triples):
      - Replica 1, primary of view 1, durably appends ops 1..5. Op 1 is committed cluster-wide; ops
        2..5 are held by replica 1 ALONE (their Prepares never reached anyone). Replica 1 is then
        partitioned off.
      - Replicas 2 and 3 carry on without it: they complete view changes to view 2 and then view 3,
        selecting a log of length 1 (neither of them ever had ops 2..5), and commit two genuinely
        DIFFERENT values at ops 2 and 3 along the way. Their true state is now
        [last_normal_view = 3], [op_number = 3], [commit_number = 3]. Replica 1's true (and now
        lost) state is [last_normal_view = 1], [op_number = 5].
      - Replica 1 crashes with a torn superblock. Following the retracted advice, the operator reads
        replica 2's CURRENT values -- [view_number = 3], [last_normal_view = 3], [commit_number = 3]
        -- and supplies them. Every face-validity check below passes: they are non-negative,
        [3 <= 5], [3 <= 3].
      - In the next view change, replica 1 is [Primary(4)] and collects the DVC quorum. Every DVC
        now claims [last_normal_view = 3], so [WinningDVC] falls through to its tie-break on
        [n] -- and replica 1 WINS with [n = 5] against the survivors' [n = 3]. [FillValue] prefers
        the winner's own entries, so ops 2 and 3 are rebuilt from replica 1's STALE view-1 values,
        while [HighestCommitNumber] (a separate maximum, VSR.tla:257-260) independently carries
        [k = 3] forward. The [StartView] then installs that log on every LIVE replica (replica 3,
        whose own last act started this view change, is permanently gone by then -- tolerating the
        loss of one replica out of 2f+1 is exactly what VSR is for, so an unreachable machine's disk
        is not a copy the protocol can ever use). Two committed, client-acknowledged operations have
        been replaced by different values at the same op-numbers, and are reported committed.
      - Rebuilt instead with replica 1's OWN true prior state ([view_number = 1],
        [last_normal_view = 1], [commit_number = 1]), its DVC honestly reports the LOWER
        [last_normal_view], loses selection to the survivors' [last_normal_view = 3], and the
        cluster keeps its real committed ops 2 and 3 -- while replica 1's uncommitted ops 4..5 are
        correctly truncated.

      Nothing in this function's checks, or in {!Riptide_vsr.Replica}'s own
      [handle_do_view_change] validation, can catch the over-claiming case:
      [handle_do_view_change] validates a DVC's [entries]/[nacks]/[n]/[k]/[i]/[v] and bounds
      [last_normal_view] below the view it announces, but it cannot verify that
      [last_normal_view] is TRUE -- no receiver has any independent evidence of another replica's
      own view history. That is the whole problem, not an unimplemented check.

      Per-field, in both directions, so none of the three is optional or "probably fine at 0":
      - [last_normal_view] too LOW loses view-change log selection to a replica holding a shorter
        log (first trace). Too HIGH wins selection it has no right to and overwrites the winner's
        committed entries with its own stale ones (second trace). It is the primary sort key other
        replicas rank this one by, so it is wrong in BOTH directions, never "conservative".
      - [commit_number] too LOW removes this replica's own protection against truncating a prefix it
        knows to be committed ([truncate_wal]'s [~committed] guard), so a later view change can
        discard it locally. Too HIGH makes this replica assert, through its own DVC's [k] and into
        [HighestCommitNumber], that ops it merely holds are COMMITTED -- which is how the second
        trace's stale ops 2 and 3 end up marked committed cluster-wide.
      - [view_number] too LOW makes the replica accept as current a view the cluster has already
        abandoned. Too HIGH makes it reject the real current primary's traffic and refuse every
        [StartView] from the view actually in progress. Note also (review finding M9) that
        [view_number] must be ACCURATE, not merely non-zero: if the supplied view is one this
        replica is itself the primary of, the rebuilt replica comes back as a [Normal] PRIMARY and
        will accept [propose] calls, durably appending entries no peer may ever accept.

      {b Why the caller has to supply them at all -- this is inherent, not an unfinished
      implementation.} The WAL is the only durable state this layer has left, and it records op
      bytes, not view/commit bookkeeping. No value for [view_number], [last_normal_view] or
      [commit_number] is DERIVABLE from it, by any rule, and the honest consequence is that a
      single replica in this state genuinely cannot recover itself from local evidence alone.
      Recovering it from CROSS-REPLICA evidence is VSR's classical Recovery sub-protocol, which is
      real Layer-0 consensus-protocol scope (its own messages, its own quorum argument, its own
      TLA+ verification under this repo's own governance rules) and deliberately out of this
      function's scope.

      {b WHEN THIS TOOL IS HONESTLY SAFE TO USE -- and the disclosed limitation when it is not.}
      There is no known safe GENERAL procedure for externally sourcing these three values, and in
      particular no procedure that queries other replicas: any peer's present state describes a
      DIFFERENT replica's progress, not this one's. This function is therefore safe to call in
      exactly one situation: {b the operator has independent, out-of-band certainty of THIS
      replica's own prior durable state} -- for example an external monitoring/audit trail that
      recorded this replica's own view transitions and commit progress in real time, BEFORE it
      crashed, so the triple is read back from a record of this replica's own history rather than
      inferred from anything currently live. If no such independent record exists, {b this tool
      cannot be used safely, and there is no substitute for it in this codebase.} That is a real,
      disclosed limitation of the feature, stated here rather than papered over with a procedure
      that looks actionable and is not: a replica in this state with no trustworthy record of its
      own prior view/commit state must be discarded wholesale and rejoin as an empty replica (which
      costs its uniquely-held data, but cannot corrupt anyone else's), or wait for a real Recovery
      sub-protocol. What this function is, precisely, is the mechanical last step of a recovery
      whose EVIDENCE came from somewhere this layer cannot see -- strictly better than the
      alternative it replaced (a replica permanently down with a fully intact log and no supported
      way to bring it back) for an operator who has that evidence, and strictly worse than a real
      Recovery protocol for one who does not.

      {b Preconditions}, both of them exactly {!Riptide_vsr.Replica.restart}'s own fail-stop
      condition, so this function is callable precisely in the state that guard refuses in:
      @raise Invalid_argument if [superblock_read t <> None] -- this function REPAIRS a lost
        superblock, it never overwrites one that is still perfectly good.
      @raise Invalid_argument if [wal_highest_durable_op_number t = 0] (review finding M8; the
        DURABLE reading, matching {!Riptide_vsr.Replica.restart}'s own guard exactly) -- an empty
        backend is FIRST BOOT, not a lost superblock, and writing a degenerate superblock there
        repairs nothing while permanently foreclosing {!Riptide_vsr.Replica.create} (which refuses
        if any superblock already exists).
      @raise Invalid_argument if the supplied values are not well-formed on their face: any of them
        negative, [commit_number > op_number]
        ([CommitNumberNeverHigherThanOpNumber], VSR.tla:721-722), or
        [last_normal_view > view_number]. See {!Riptide_storage.Superblock_record.check_rebuild_values}
        -- and note that passing these checks says nothing at all about whether the values are TRUE.

      {b Postcondition: [superblock_read t] returns [Some] afterward}, of a record
      {!Riptide_vsr.Replica.restart} can actually decode and use -- not merely "some bytes". The
      schema is {!Riptide_storage.Superblock_record}'s, the same single definition
      {!Riptide_vsr.Replica}'s own durable writes go through, so the two cannot drift.

      {b [op_number] is derived in the OVER-reporting direction, deliberately} (review finding 2) --
      it is exactly {!wal_highest_durable_op_number}, never {!wal_highest_op_number}. A
      backend derives it as the highest op-number whose slot HEADER still verifies and sits at the
      ring position that op-number belongs to -- {b regardless of whether that slot's DATA also
      verifies}. Requiring the data to verify too would UNDER-report, which is the one direction
      that is unsound: [Riptide_vsr.Replica]'s own [adopt_durable_log] ("CRASH ORDERING") spells out
      why over-reporting is the safe side -- a replica that reports an op-number it cannot fully
      read presents those slots as VSR.tla's "corrupt" (in range, unreadable, never shipped and
      never nacked), whereas one that reports a LOWER op-number proves them ABSENT via
      [sender_proves_absent]'s [o > n] disjunct, which is precisely the "corrupt -> absent" mutation
      TLC refuted against [NoCommittedOpProvablyAbsent] (VSR.tla:111-150). Over-reporting costs
      liveness (the replica declines new Prepares until a StartView repairs the unreadable slots);
      under-reporting costs committed data.

      {b Residual gap this repair does NOT cover, stated plainly} (review finding 4).
      {!Riptide_vsr.Replica.restart} refuses on either of TWO shapes of unusable superblock:
      [superblock_read = None], and [superblock_read = Some bytes] where those bytes do not decode
      as a superblock record. This function's precondition only admits the FIRST. A backend that
      still hands back bytes -- a majority of copies agreeing on a record that is nonetheless
      garbage -- cannot be repaired by this function; it raises [Invalid_argument] instead, and that
      failure mode has no repair tool in this codebase. The reason is a layering constraint, not an
      oversight: deciding "present but garbage" from "present and fine" means DECODING a
      VSR-shaped record and judging its fields, and while
      {!Riptide_storage.Superblock_record.decode} now makes the decode itself available down here,
      judging whether a decodable record is the RIGHT one is a protocol question this layer has no
      standing to answer -- a superblock that decodes cleanly but describes the wrong state is
      exactly what a caller must NOT have silently overwritten out from under it. In practice such a
      backend is recovered the way this contract's own text describes for the un-repairable case:
      wipe it and let it rejoin as an empty replica. *)
  val superblock_rebuild_from_wal :
    t -> view_number:int -> last_normal_view:int -> commit_number:int -> unit
end
