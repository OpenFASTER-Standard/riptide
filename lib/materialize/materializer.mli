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
      across separate [get] + [put] calls. *)

  val read : t -> merge_key:string -> L.t
  (** [read t ~merge_key] returns the current accumulated value at [merge_key], or [L.bottom]
      if the key has never been written. The value reflects all [write] calls that have
      completed so far (synchronous fold: returned value is always current after every
      [write] returns). *)
end
