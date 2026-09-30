exception Value_too_large of string
(** Raised by {!Make.write} when the merged accumulator's encoded size exceeds the underlying
    [KV]'s own value-size bound (see {!Make.write}'s own doc comment for the full account of when
    and why this happens, and what it means for the accumulator). Carries the same message
    [KV.put]'s own [Invalid_argument] raised, unchanged.

    Declared here, at this module's own top level, rather than nested inside {!Make}'s functor
    body: {!Make} is a generative functor, so a type or exception declared inside its body would
    be a genuinely different one per application, unusable by a caller that only ever holds an
    erased sink over an unknown concrete [L]/[KV] (see
    {!Riptide_batch_commit.Batch_commit.materialize_sink}). One shared, top-level exception lets
    such a caller catch this ONE specific, documented failure shape by name regardless of which
    lattice or KV backend actually raised it -- the same precedent
    {!Riptide_vsr.Replica.Sender_mismatch} already sets in lib/vsr/replica.mli.

    {b Deliberately narrower than "any [Invalid_argument] raised anywhere inside [write]"}: only
    the [KV.put] call itself is wrapped and translated into this exception. A [decode]/[encode]
    bug of the caller's own (e.g. {!Riptide.Value.canonical_encode}'s own documented
    duplicate-Record/Map-key [Invalid_argument]) is a genuine value-layer contract violation and
    still propagates as a plain, uncaught [Invalid_argument] -- never conflated with this. *)

module Make (L : Riptide_lattice.Lattice_intf.S) (KV : Riptide_storage.Kv_store_intf.S) : sig
  type t
  (** Incremental, lattice-based accumulator over a durable key-value store. Each [merge_key]
      holds the join of all values ever written to it via {!write}. *)

  val create : kv:KV.t -> owner:string -> decode:(string -> L.t) -> encode:(L.t -> string) -> t
  (** [create ~kv ~owner ~decode ~encode] creates a materializer backed by [kv], with
      [decode]/[encode] for round-tripping the lattice type [L.t] to/from the store's string
      value format. Durably folds all future [write] calls to the same [merge_key] into a single,
      live accumulator — the join of all values ever seen, regardless of call order.

      {b [kv] is received already built, never constructed here}, and {b [~owner] is a
      self-consistency assertion, NOT a collision guard} -- stated precisely because the
      distinction is easy to overstate. This functor is generic over
      {!Riptide_storage.Kv_store_intf.S}, and every implementer of that module type gives a real
      [owner] accessor (a backend with no genuine ownership/collision-risk concept of its own may
      return a fixed placeholder instead), so [create] compares [owner] against [KV.owner kv] and
      rejects a mismatch before a usable [t] is ever constructed. But {b the same caller supplies
      both sides of that comparison} -- [kv]'s tag came from whatever [create] call built [kv], and
      [owner] comes from this call -- so the check can only ever catch a caller contradicting
      ITSELF: a typo, or a copy-paste that passes [~owner:"a"] to
      {!Riptide_storage.File_kv_store.create} and [~owner:"b"] here. A caller that tags both sides
      consistently always passes, whether or not the tag it chose is the right one for this use:
      [create ~kv ~owner:(File_kv_store.owner kv) ~decode ~encode] typechecks and succeeds for any
      [kv] whatsoever. What the check does buy is that a [Materializer]'s namespace is now
      {e explicitly declared} at its own construction site rather than silently inherited from
      whatever built [kv].

      {b Whatever real collision protection exists comes entirely from
      {!Riptide_storage.File_kv_store.create}'s own marker-file mechanism} (subtask 4.6, a
      different and earlier part of the same work), not from this check -- and even that catches
      only a MISMATCHED tag on a shared directory, so an accumulator and a
      {!Riptide_crypto.Redaction_store} keystore sharing one directory under the SAME tag still
      silently destroy each other's data. That residual gap is real and still open; see
      {!Riptide_crypto.Redaction_store.create}'s own doc comment for the full account and for the
      running tests on both sides of it.

      Unlike {!Riptide_crypto.Redaction_store.owner_tag}, there is no single, project-wide constant
      for this module's own expected owner: different [Materializer] instances serve different
      [merge_key] namespaces backed by different directories, so the caller supplies whatever tag
      it built its own [kv] with (e.g. ["materializer"] is the convention every real caller in this
      codebase's tests uses today -- this module has no non-test callers yet).

      @raise Invalid_argument if [KV.owner kv <> owner]. *)

  val write : t -> merge_key:string -> L.t -> unit
  (** [write t ~merge_key value] durably merges [value] into the accumulator at [merge_key]
      in the same call (synchronous fold: the [write] returns only after the merged result is
      durable in {!KV.t}, making ring-eviction safe by construction).

      {b Task 20: concurrent writers to the SAME [merge_key] on the SAME [t] are safe.} The
      implementation still uses a read-join-put pattern internally -- it reads the current value,
      computes the join with the new value, then writes the result back, and {!KV.get}/{!KV.put}
      still perform real async I/O that yields to other fibers mid-call -- but [write] now holds a
      private, per-[merge_key] {!Eio.Mutex.t} (created lazily, the first time any fiber writes
      that key, and kept for the rest of [t]'s lifetime) around that whole sequence. Two fibers
      can no longer both read the same stale value for one [merge_key] and race their [put]s: one
      completes its full read-join-put before the other's even starts reading. The accumulator at
      a given [merge_key] is therefore always the join of every value passed to a [write] call
      that has returned, regardless of how many fibers wrote it concurrently or in what order --
      before this fix, a live reproduction of 16 concurrent writers to one [merge_key] lost 15 of
      them, deterministically (exactly 1 survivor, every run).

      This is per-[merge_key] mutual exclusion, not one lock over all of [t]: writers to two
      DIFFERENT [merge_key]s are never serialized against each other and proceed fully
      concurrently, exactly as before this fix -- only writers racing on the identical key wait on
      one another.

      The guarantee is scoped to writers sharing this one [t] value. A second [Materializer.t]
      built by a separate {!create} call -- even one pointed at the very same underlying [kv] --
      has its own, independent table of per-[merge_key] mutexes and is NOT serialized against the
      first; nothing here prevents two different [t]s from racing each other's [KV.get]/[KV.put]
      calls the original, unsafe way. This limitation is inherited from {!Kv_store_intf.S} exactly
      as before, just narrowed from "every caller" to "every caller sharing one [t]": it still does
      not promise atomicity of a [get] + [put] pair issued by two different [KV.t] handles (or two
      different [Materializer.t]s over the same handle).

      {b New resource cost introduced by this fix, distinct from the accumulator-value-size WARNING
      below (this one is about the lock table's own memory, not about anything stored in [KV]):}
      [t] retains one small [Eio.Mutex.t] per distinct [merge_key] ever written through it, for the
      rest of [t]'s lifetime -- this table is never pruned, so a caller that writes an unbounded
      number of distinct [merge_key]s through one long-lived [t] accumulates an unbounded number of
      mutexes alongside it. Building an eviction/GC mechanism for this table is out of scope for
      this fix.

      WARNING, and it is reached by ordinary use rather than misuse: an accumulator is the join of
      every value ever written to its [merge_key], so for a grow-only lattice it grows without
      bound -- while a real [KV] backend's single value is bounded
      ({!Riptide_storage.File_kv_store.max_value_size}, 4096 bytes, is the only backend this repo
      ships). Once [encode]'s output for the merged accumulator exceeds that, [KV.put] raises
      [Invalid_argument], which [write] catches -- narrowly, wrapped tightly around just that one
      call, {b not} around [decode]/[L.join]/[encode] themselves, see {!Value_too_large}'s own doc
      comment for why that narrowness is load-bearing -- and re-raises as {!Value_too_large} of the
      same message. Nothing is stored, so THIS write is silently absent from the
      accumulator while remaining wherever the caller put it -- in
      {!Riptide_batch_commit.Batch_commit.propose}'s case, durably committed to the replicated log,
      since the fold deliberately runs only after commit. The accumulator is left at its last good
      value, so a subsequent SMALLER write to the same [merge_key] succeeds and nothing surfaces
      the gap again.

      {b The resulting divergence is PERMANENT and has no retry-recovery path at all}, and that is
      stronger than "a documented limitation" -- it is worth stating exactly, because Task 9's fix
      to {!Riptide_batch_commit.Batch_commit.propose} deliberately made it so. Materialization now
      re-reads the batch's writes from the COMMITTED bytes (which is what makes the accumulator a
      function of the agreed log alone), so retrying the failing key re-encodes the identical
      payload, re-joins it into the identical accumulator, and hits the identical size cap, forever
      -- on this replica and on every other one, since they all read the same committed bytes.
      Before that fix a caller could at least retry the same [idempotency_key] with a smaller
      regenerated batch and get {e something} folded in; that escape hatch is gone by design (it was
      itself the divergence bug the fix closed). There is no in-band repair: the only ways out are
      to reduce what the lattice holds at that [merge_key] (which a grow-only lattice cannot do) or
      to move the store to a backend whose value bound is large enough. And because a later,
      smaller write to the same [merge_key] still succeeds silently, a store carrying such a gap
      goes on looking healthy indefinitely. Found and measured by Task 9's end-to-end proof
      (test_lattice_materialize_crypto_scenarios.ml, which pins the exact behaviour); no fix is
      attempted here, because both candidate fixes -- spilling a large value across slots in the
      backend, or giving {!Kv_store_intf.S} a declared bound this module checks before folding --
      are real design decisions rather than an oversight to patch. A caller whose lattice can grow
      unboundedly must either bound it itself or choose a backend that can hold it. *)

  val read : t -> merge_key:string -> L.t
  (** [read t ~merge_key] returns the current accumulated value at [merge_key], or [L.bottom]
      if the key has never been written. The value reflects all [write] calls that have
      completed so far (synchronous fold: returned value is always current after every
      [write] returns). *)
end
