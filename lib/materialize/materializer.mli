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

      WARNING: Not concurrency-safe for genuinely concurrent writers to the *same* [merge_key].
      The implementation uses a read-join-put pattern: it reads the current value, computes the
      join with the new value, then writes the result back. Because {!KV.get} and {!KV.put}
      perform real async I/O and yield to other fibers, two concurrent [write] calls on the same
      [merge_key] can both read the same stale value, compute different merges, and the second
      [put] silently overwrites the first's contribution — a classic lost-update race.

      If multiple fibers must write the same [merge_key] concurrently, the caller must
      serialize those writes itself (e.g., by using one fiber/serial queue per [merge_key]).
      This limitation is inherited from {!Kv_store_intf.S}, which does not promise atomicity
      across separate [get] + [put] calls.

      WARNING, and it is reached by ordinary use rather than misuse: an accumulator is the join of
      every value ever written to its [merge_key], so for a grow-only lattice it grows without
      bound -- while a real [KV] backend's single value is bounded
      ({!Riptide_storage.File_kv_store.max_value_size}, 4096 bytes, is the only backend this repo
      ships). Once [encode]'s output for the merged accumulator exceeds that, [KV.put] raises
      [Invalid_argument] and nothing is stored, so THIS write is silently absent from the
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
