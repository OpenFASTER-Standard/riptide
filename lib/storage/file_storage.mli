(** A [Storage.S] backend: a fixed-size ring WAL with redundant, physically-separate headers
    (op_number/length/checksum), backed by real [O_DIRECT]+[O_DSYNC]-durable writes via
    [eio_linux]'s low-level [io_uring] API where the underlying filesystem supports it, falling
    back to [O_DSYNC] alone automatically where it doesn't. Every read/write acquires a
    guaranteed-page-aligned, [mmap]-backed buffer -- the same allocate-aligned-buffer /
    [O_DIRECT]-write / read alignment technique validated with 2500 real operations across both an
    ext4 and an overlayfs mount with zero failures -- from a small, fixed-size pool owned by [t]
    (allocated once at [create], explicitly acquired/released around each read/write, never a
    fresh [mmap] per I/O; the pooling arrangement itself is new as of Task 10 and post-dates that
    2500-operation validation run, which exercised the alignment technique alone, one fresh
    [mmap] per I/O). See {!Riptide_storage.File_storage}'s own [.ml] top comment for: the exact
    on-disk ring/header layout; why Task 1's version of this module had to drop [O_DIRECT] (a
    shared fixed-buffer pool with no alignment guarantee); how this version makes [O_DIRECT] work
    for real; and (that same comment's own "Task 10" section) why the buffers are drawn from a
    pool rather than [mmap]'d fresh per I/O -- the per-I/O version leaked kernel VMA mappings with
    no bound, eventually crashing the process. *)

include Storage_intf.S

val create :
  sw:Eio.Switch.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  ring_capacity:int ->
  ?may_evict:(op_number:int -> bool) ->
  string ->
  t
(** [create ~sw ~fs ~ring_capacity dir_path] opens (creating if necessary) a ring WAL directory
    at [dir_path]. [ring_capacity] is the number of fixed-size slots the ring holds
    -- [wal_append] of op_number [n] overwrites whatever was previously at op_number
    [n - ring_capacity], if anything.

    {b [ring_capacity] is REQUIRED, with no default}, which is a deliberate change (final-review
    finding I4): it used to default to [8]. Overwriting op_number [n - ring_capacity] means
    silently destroying an entry this module's own [wal_append] already promised was durable, and
    nothing in this system ever truncates a committed prefix away (there is no checkpointing), so
    every entry stays live forever and a log longer than the ring destroys committed,
    client-acknowledged data with no signal to any caller. The protocol-level consequence is
    total and needs no injected faults — see [test/test_dst_scenarios.ml]'s own ring-capacity
    boundary test, which reproduces a permanently wedged cluster past the bound. Pairing that with
    a small, invisible default was backwards; raising the default would only have made it a
    less-likely-to-bite invisible default. A caller must now state the bound it is accepting.

    [wal_highest_op_number] is recovered by scanning every slot's header (and validating each
    one's checksum against that slot's own data) on [dir_path] as it already exists on disk, so
    reopening the same directory after a process restart picks up exactly where the previous
    process left off, including across ring wraparound.

    {b This recovery scan is O([ring_capacity]), not O(the number of entries actually written)} --
    it always reads every one of [ring_capacity]'s slots (a real, aligned [O_DIRECT] header read
    each, and a matching data read for any slot whose header looks occupied), never fewer, since
    nothing durable on disk records how many slots are actually live short of reading each one.
    Audit-remediation Task 19 measured this at roughly {b 53 µs/slot} on this box's own mounts, so
    [create]'s (and, after a crash, [Riptide_vsr.Replica.restart]'s) one-time cost scales linearly
    with [ring_capacity] alone, independent of how full the ring actually is: a modest
    [ring_capacity] of 10,000 costs on the order of 530 ms before [create] returns; a
    [ring_capacity] of 1,000,000 (sized, say, for a workload that never wants to evict) costs on
    the order of 53 seconds -- a real, one-time startup/restart cost worth weighing directly
    against how large a caller actually needs this ring to be, not just against the eviction
    behaviour the "REQUIRED, with no default" note above already covers.

    [File_storage]-specific limitation, not part of the abstract {!Storage_intf.S} contract:
    [wal_append] raises [Invalid_argument] for any entry larger than one aligned data slot
    (currently 4096 bytes), since each slot holds exactly one entry's data, zero-padded to the
    slot's fixed size.

    {b Task 11: a real, OS-level lock, not merely this module's own file-open calls.} [create]
    takes a real [flock(2)] on [dir_path] (via {!Riptide_storage.Dir_lock.acquire}) before opening
    any of its own files, held for the returned [t]'s entire lifetime.

    @raise Invalid_argument immediately, before touching any file this module itself manages, if
      [dir_path] is already locked by another live handle -- this process's own, from an earlier
      [create] of the same directory that hasn't gone out of scope yet, or a genuinely different
      OS process's. This is a PHYSICAL guard against concurrent construction, independent of
      anything a caller above this module tracks logically; see
      {!Riptide_storage.Dir_lock}'s own [.mli] for the full rationale and how it differs from
      {!Riptide_storage.File_kv_store.create}'s [~owner] marker.

    {2 [?may_evict] — the caller's veto over an eviction}

    [?may_evict] makes the silent data loss described above {e refusable} rather than merely
    documented. It is the owner's answer to one question, asked at the one moment it matters:
    {e may op_number [n] stop being readable now?}

    - {b When it is consulted.} Only when an append genuinely overwrites a live prior entry —
      i.e. when the appended [op_number] exceeds [ring_capacity]. Op-numbers
      [1 .. ring_capacity] land in slots no op-number has ever occupied, so a ring-filling prefix
      consults the predicate {e zero} times. Both pre-existing argument checks run first (see
      below), so the predicate is never consulted for a call that was going to be rejected anyway.
    - {b What it receives.} The op-number {b about to be evicted}, which is
      [op_number - ring_capacity] — {e not} the op-number being appended. Appending op_number
      [ring_capacity + 1] asks about op_number [1].
    - {b What [false] does.} [wal_append] raises
      [Invalid_argument "wal_append: eviction blocked for op_number <n>"], where [<n>] is the
      evicted op-number the predicate was just asked about.
      {!Riptide_vsr.Replica}'s [classify_append_refusal] recognizes that
      ["wal_append: eviction blocked for op_number "] prefix as its [Eviction_blocked] refusal
      shape, so the refusal arrives at the protocol layer already told apart from the other three
      (and is counted in {!Riptide_vsr.Replica.append_refusals}) rather than as an unclassifiable
      exception that would propagate. Rewording this message is therefore a cross-module change:
      [test_vsr_replica_recovery.ml]'s own discrimination test drives a real refusal from this
      module through a real replica and fails if the two sides drift apart.
    - {b A refusal is a clean no-op.} Nothing is written, [wal_highest_op_number] does not advance,
      and the entry that would have been evicted stays readable. Retrying the {e same} [op_number]
      after the predicate relents is therefore sound and is the intended usage — the refusal is
      backpressure, not a permanent rejection of the entry.

      {b This "clean no-op" guarantee is specific to the two [Invalid_argument] guard-failure
      refusals ([?may_evict] declining, and an oversized entry) — it does NOT extend to a genuine
      I/O failure (Task 12, audit-remediation Decision 3.3; the [Eio.Io]/[Unix.Unix_error] shape
      {!Riptide_vsr.Replica.durable_append} classifies as [storage_fault]).} [wal_append] below
      writes a slot's header, then its data, as two SEPARATE, non-atomic writes (see the [.ml]'s own
      comment above [write_header]/[write_data]); an I/O failure raised between them can leave the
      ring slot's PRIOR occupant permanently unreadable ([Corrupt], per [wal_read]) — including one
      a [?may_evict] predicate had refused to let be evicted moments earlier, on an EARLIER call
      that relented before this one was attempted (within a single [wal_append] call the predicate,
      if it refuses, always fires before either write, so it is never the occupant this specific
      call is in the middle of overwriting) — regardless of which of the two
      writes the failure landed between. This is an inherent property of a two-write update to a
      fixed slot, not a bug in either write's ordering: whichever write happens first, a fault
      before the second one always risks losing whatever the first one just overwrote.
    - {b Precedence.} The two pre-existing [Invalid_argument] refusals both win over this one: an
      out-of-sequence [op_number], and an entry too large for one data slot, are each reported as
      themselves even when the same call would also have evicted a blocked op-number. They mean
      "this call is malformed" / "this entry can never be durable here"; a blocked eviction means
      "not yet". Conflating the two would both mislead a retrier and inflate [eviction_blocked]'s
      count, whose whole value is as a trustworthy signal that materialization has fallen behind.
    - {b Omitting it preserves this module's exact pre-existing behavior.} With no [?may_evict],
      every eviction proceeds silently, as it always did — which is what every call site that does
      not pass it relies on.
    - {b Its protection is scoped to one process's lifetime} (final-review finding I1). After a
      restart over a ring that has already wrapped, a predicate driven by
      {!Riptide_batch_commit.Batch_commit.write_at_op_number_has_merge_key} can no longer see the
      entries the ring already evicted — {!Riptide_vsr.Replica.restart}'s log rebuild is a
      contiguous scan up from op 1 and this ring always evicts the lowest live op-number first, so
      the rebuilt log it reads is empty — and it cannot protect what it can no longer observe. See
      that function's own doc comment for the honest post-restart watermark bound this implies.

    The predicate is in-memory state on the returned [t] and is deliberately not persisted: it is a
    policy, supplied afresh on each [create], evaluated against whatever [wal_highest_op_number]
    recovery found already on disk. *)

val ring_capacity : t -> int
(** [ring_capacity t] is the fixed slot count [t] was constructed with -- the same value passed to
    {!create}'s own required [~ring_capacity] argument, read back rather than tracked separately
    by a caller that already holds a [t]. Exists chiefly for the resize-before-wedge runbook
    below, which needs an OLD store's own capacity to compute where its still-live entries
    begin. *)

val ring_margin : t -> int
(** [ring_margin t] is how many more entries [t]'s ring can accept before the NEXT append would
    have to evict something.

    {b Task 31 (audit-remediation): the proactive, before-the-fact counterpart to
    {!Riptide_vsr.Replica.append_refusals}'s [eviction_blocked]}, which only reports a refusal
    AFTER {!create}'s own [?may_evict] has already declined one. A caller watching [ring_margin]
    fall toward [0] can act -- resize via the runbook below, or otherwise relieve whatever
    [?may_evict] policy it supplied -- before a single eviction is ever attempted, rather than
    discovering the problem only once [eviction_blocked] has already started climbing.

    [ring_capacity t] minus the number of entries currently live: before the ring has ever wrapped
    ([wal_highest_op_number t <= ring_capacity t]), every appended entry is still live, so that
    count is exactly [wal_highest_op_number t]; once it has wrapped, exactly [ring_capacity t]
    entries are live at any one time (each new append evicts exactly one older one), so the live
    count saturates at [ring_capacity t] and [ring_margin] saturates at [0]. It does not go
    negative, and it does not distinguish "just wrapped" from "wrapped long ago" -- both report
    [0], which is the correct reading for an early-warning signal: the next append will evict
    something either way, and how long that has already been true is not this function's
    question. *)

val wal_seed_starting_op_number : t -> op_number:int -> unit
(** [wal_seed_starting_op_number t ~op_number] declares that [t]'s WAL begins at [op_number]
    rather than [1] -- the one primitive the resize-before-wedge runbook below needs, and the only
    reason this function exists; no other caller in this codebase should ever reach for it.

    {b Why it is needed at all.} {!wal_append}'s own sequencing guard requires
    [op_number = wal_highest_op_number t + 1] on every call, unconditionally -- correct for the
    ordinary case (a backend's WAL always starts at op 1), but exactly what makes it otherwise
    impossible to seed a FRESH backend with only the still-live SUFFIX of another ring's WAL: that
    suffix's first real op-number is whatever the old ring's own eviction left as its oldest
    survivor, almost always well above 1, and there is no data left anywhere to replay the ops
    below that point (the old ring already evicted them). This function is the escape hatch: it
    moves [t]'s own bookkeeping forward without writing anything, so the very next {!wal_append}
    can legally be [op_number] instead of [1].

    @raise Invalid_argument if [wal_highest_op_number t <> 0] -- this seeds a VIRGIN backend's
      starting point; it never fast-forwards one that already holds real appended state (whether
      from this same process or recovered from disk on {!create}), which would silently discard
      the difference between "genuinely never written" and "written, then this call pretended it
      wasn't".
    @raise Invalid_argument if [op_number < 1].

    {b What reads back for every op-number below [op_number], forever.} [None] -- {!wal_read}'s
    own out-of-range/never-written case, reached the same way it already is (nothing is written to
    disk for them, so a header scan finds nothing there either, on this handle or after a later
    reopen). That is the honest representation: those op-numbers' real data is gone (evicted by
    whatever ring this store's data was copied from), and this function deliberately provides no
    way to fabricate a readable substitute for them.

    {b Purely in-memory, and cheap for exactly that reason.} No header or data slot is touched, so
    a REOPEN of [t]'s directory never needs to know this call happened: {!create}'s own recovery
    scan finds [op_number] and above's real headers on disk and recovers the same
    [wal_highest_op_number] this call only ever approximated in memory for the one live handle
    that made it. *)

(** {2 The resize-before-wedge runbook (Task 31, audit-remediation)}

    How to move a replica's WAL from a smaller ring to a larger one BEFORE the smaller one wedges
    (either from ordinary eviction destroying data a caller still needs, or from {!create}'s own
    [?may_evict] permanently refusing further appends) -- using only the primitives above, with no
    dedicated "resize" entry point of its own. Watch {!ring_margin} approach [0] (or
    {!Riptide_vsr.Replica.append_refusals}'s [eviction_blocked] start climbing) as the trigger to
    run this, rather than a fixed schedule.

    {[
      let old_t = (* the existing, near-full (or already-wrapped) store *) in
      let new_t = File_storage.create ~sw ~fs ~ring_capacity:bigger_capacity new_dir in
      let old_highest = File_storage.wal_highest_op_number old_t in
      (* THE SUBTLETY: where to start copying FROM. Naively starting at op 1 works only while
         [old_t]'s ring has never wrapped; once it has, ops below this point were already
         evicted, and [wal_read] returns [None] for them -- indistinguishable, from the read call
         alone, from "the log simply doesn't reach that far yet". Treating an early [None] as
         "done, nothing more to copy" either copies nothing at all (if op 1 already happens to be
         evicted) or stops after copying only a prefix of the truly-live range -- both silent
         under-copies. The correct starting point is the OLDEST entry [old_t] can still prove
         live: *)
      let start = max 1 (old_highest - File_storage.ring_capacity old_t + 1) in
      (* Real op-numbers, not a renumbering from 1: this store's WAL is (or backs) a live
         replica's actual consensus log, and [wal_highest_op_number]/[wal_append]'s own
         sequencing guard are both stated in terms of the SAME op-numbers the replica itself
         tracks -- a copy that renumbered starting at 1 would leave [new_t] reporting a
         [wal_highest_op_number] wildly disagreeing with what the replica believes its own log
         holds. *)
      if start > 1 then File_storage.wal_seed_starting_op_number new_t ~op_number:start;
      for op_number = start to old_highest do
        match File_storage.wal_read old_t ~op_number with
        | None ->
          (* Only reachable if [old_t] misreported its own [wal_highest_op_number], or [start]
             above was computed wrong -- both a bug in this procedure, never a normal outcome; a
             real runbook should treat this as a hard failure; it means "not live" and "once
             wrapped and never written" are actually cases that dropped this entry silently. *)
          invalid_arg
            (Printf.sprintf "resize: op_number %d expected live, read back None" op_number)
        | Some data -> File_storage.wal_append new_t ~op_number data
      done
    ]}

    {b [new_t]'s [ring_capacity] must be at least the number of entries actually being copied}
    ([min old_highest (File_storage.ring_capacity old_t)]) -- the whole point of resizing is that
    none of them get re-evicted by the copy itself. Passing a "larger" capacity that still is not
    large enough silently defeats the runbook rather than erroring: an eviction during the copy
    looks exactly like any other eviction to this module.

    {b Do this copy against a [new_t] created WITHOUT [?may_evict].} [?may_evict]'s own gate (see
    {!create}) decides whether to evict purely from OP-NUMBER ARITHMETIC ([op_number >
    ring_capacity]), not from whether [new_t] itself ever really held a prior occupant at that
    slot -- correct for an ordinary store (which always starts at op 1, so the arithmetic and real
    occupancy always agree), but not for one seeded mid-sequence by this runbook: for every
    [op_number] up to [start + File_storage.ring_capacity new_t - 1], the arithmetic points at an
    op-number below [start] that [new_t] never actually wrote, and a supplied predicate would be
    asked to bless evicting an entry that, from [new_t]'s own point of view, was never there to
    lose in the first place. If ongoing [?may_evict] protection is wanted for [new_t] going
    forward, attach it on a FRESH {!create} of the same directory once the copy above has
    completed -- that reopen's own recovery scan re-derives [wal_highest_op_number] from the real
    headers the copy just wrote, so it needs none of [wal_seed_starting_op_number]'s bookkeeping,
    and the arithmetic-vs-occupancy mismatch above no longer applies to appends made from that
    point on (though it can recur for another [File_storage.ring_capacity new_t] appends past
    THAT point too, for the identical underlying reason -- this is a property of resizing a ring
    at all, not specific to any one implementation choice here, and is disclosed rather than
    solved). *)
