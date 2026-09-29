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

  (** 0 if the WAL is empty. *)
  val wal_highest_op_number : t -> int

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
      three supplied values must be the replica's REAL durable view/commit state, obtained from a
      live, trusted, surviving peer of the same cluster (its [view_number], its
      [last_normal_view], and this replica's own commit-number as that peer understands it).
      Supplying values this storage layer could have invented on its own -- in particular ZEROS,
      which is what the first cut of this function silently wrote -- converts VSR's own safe
      permanent-stall failure mode into SILENT, CLUSTER-WIDE LOSS of a committed,
      client-acknowledged operation. That is not a theoretical concern; it is a concrete
      three-replica trace, and it is pinned by a real running test
      ([test/test_vsr_replica_recovery.ml]'s
      [test_a_rebuild_with_zeroed_values_destroys_a_committed_op_through_a_view_change],
      [test_a_rebuild_with_only_last_normal_view_wrong_still_destroys_it] and
      [test_a_rebuild_with_correct_values_preserves_that_same_committed_op] -- three runs of the SAME
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

      The same reasoning applies to each field separately, so none of the three is optional or
      "probably fine at 0":
      - [last_normal_view] too LOW loses view-change log selection to a replica holding a shorter
        log, as traced above.
      - [commit_number] too LOW removes this replica's own protection against truncating a prefix it
        knows to be committed ([truncate_wal]'s [~committed] guard), so a later view change can
        discard it locally.
      - [view_number] too LOW makes the replica accept as current a view the cluster has already
        abandoned. Note also (review finding M9) that [view_number] must be ACCURATE, not merely
        non-zero: if the supplied view is one this replica is itself the primary of, the rebuilt
        replica comes back as a [Normal] PRIMARY and will accept [propose] calls, durably appending
        entries no peer may ever accept.

      {b Why the caller has to supply them at all -- this is inherent, not an unfinished
      implementation.} The WAL is the only durable state this layer has left, and it records op
      bytes, not view/commit bookkeeping. No value for [view_number], [last_normal_view] or
      [commit_number] is DERIVABLE from it, by any rule, and the honest consequence is that a
      single replica in this state genuinely cannot recover itself from local evidence alone.
      Recovering it from CROSS-REPLICA evidence is VSR's classical Recovery sub-protocol, which is
      real Layer-0 consensus-protocol scope (its own messages, its own quorum argument, its own
      TLA+ verification under this repo's own governance rules) and deliberately out of this
      function's scope. What this function is, precisely, is the mechanical last step of that
      recovery once a human has obtained the values some other way -- which is strictly better than
      the alternative it replaced (a replica permanently down with a fully intact log and no
      supported way to bring it back), and strictly worse than a real Recovery protocol.

      {b Preconditions}, both of them exactly {!Riptide_vsr.Replica.restart}'s own fail-stop
      condition, so this function is callable precisely in the state that guard refuses in:
      @raise Invalid_argument if [superblock_read t <> None] -- this function REPAIRS a lost
        superblock, it never overwrites one that is still perfectly good.
      @raise Invalid_argument if [wal_highest_op_number t = 0] (review finding M8) -- an empty
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

      {b [op_number] is derived in the OVER-reporting direction, deliberately} (review finding 2). A
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
