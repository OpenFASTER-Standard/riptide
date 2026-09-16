(** A single-node, in-memory, append-only, hash-chained event log. No
    distributed consensus yet (that's a later task) - this proves the
    data model and tamper-evidence primitives against real code first. *)

type log

val create : unit -> log

(** Appends a new envelope. [sequence] and [predecessor_hash] are
    computed automatically from the log's current state - the caller
    only supplies the fields that carry real domain meaning. Returns the
    newly-created envelope (with its computed fields filled in). *)
val append :
  log ->
  actor:Envelope.actor_id ->
  causation:Envelope.event_id ->
  correlation:Envelope.event_id ->
  payload:Value.value ->
  Envelope.envelope

(** Returns the log's entries in append order (oldest first). *)
val to_list : log -> Envelope.envelope list

(** Pure: checks that each entry's [predecessor_hash] equals the content
    hash of the entry before it (or {!Envelope.genesis_marker} for the
    first entry). Exposed as a plain function over a list, not just over
    an abstract [log], specifically so tests (and later, real corruption-
    detection tooling) can check a deliberately-tampered sequence without
    needing to mutate the abstract log type. *)
val verify_chain_list : Envelope.envelope list -> bool

val verify_chain : log -> bool
