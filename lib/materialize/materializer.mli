module Make (L : Riptide_lattice.Lattice_intf.S) (KV : Riptide_storage.Kv_store_intf.S) : sig
  type t
  (** Incremental, lattice-based accumulator over a durable key-value store. Each [merge_key]
      holds the join of all values ever written to it via {!write}. *)

  val create : kv:KV.t -> decode:(string -> L.t) -> encode:(L.t -> string) -> t
  (** [create ~kv ~decode ~encode] creates a materializer backed by [kv], with [decode]/[encode]
      for round-tripping the lattice type [L.t] to/from the store's string value format.
      Durably folds all future [write] calls to the same [merge_key] into a single, live
      accumulator — the join of all values ever seen, regardless of call order. *)

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
