(** A single-node, in-memory, append-only, hash-chained event log. No
    distributed consensus yet (that's a later task) - this proves the
    data model and tamper-evidence primitives against real code first.

    Not safe for concurrent access from multiple OCaml 5 domains: [append]
    does an unsynchronized read-modify-write on the log's internal state,
    so two domains appending concurrently can race and assign a duplicate
    [sequence], forking the chain. Single-domain only for now.

    A pre-VSR-consensus prototype module, superseded by `Batch_commit` plus
    `Replica` for real replicated writes -- confirmed via a repo-wide grep to have no
    production callers as of this writing ([append] is called only from this module's own tests).
    Not a production write path, and therefore intentionally NOT covered by
    `Batch_commit.propose`'s [?require_encryption] or any of that module's
    other opt-in capabilities ([?materialize], [?encryption]) -- those are deployment-level policy
    for the real write path, and this module isn't it. *)

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
    first entry), and that each entry's [sequence] equals its 1-based
    position in the list (matching what {!append} itself assigns: [1],
    [2], [3], ...) - a hash-linked list whose sequence numbers are
    arbitrary is rejected even though the hash chain alone looks intact.
    Exposed as a plain function over a list, not just over an abstract
    [log], specifically so tests (and later, real corruption-detection
    tooling) can check a deliberately-tampered sequence without needing to
    mutate the abstract log type.

    Caveat: this cannot detect truncation of the {b tail} of a chain - a
    list missing only its last N entries still has every remaining entry's
    [predecessor_hash] and [sequence] exactly matching what a real,
    untampered prefix would have, so it verifies as [true]. Detecting that
    requires an externally-committed head (e.g. from consensus, a later
    task), not anything derivable from the entries alone; this is inherent
    to a hash chain without one, not a bug in this function. *)
val verify_chain_list : Envelope.envelope list -> bool

val verify_chain : log -> bool
