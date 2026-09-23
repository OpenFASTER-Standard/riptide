(** The redaction keystore: envelope encryption (design spec Decision 4) for content-hashed
    writes, and the one operation that makes redaction possible -- {!redact}, which deletes a
    record's wrapped DEK and nothing else.

    {b The scheme.} Every record gets its own {b freshly generated, independent} {!Dek} -- never a
    key derived from the KEK via HKDF or anything similar. That is the entire point: Kubernetes'
    own KMS v2 derives per-object keys from a shared seed for performance and, as a direct
    consequence, cannot redact one object -- the only deletable thing is the seed, which would
    erase everything. The real crypto-shredding precedent (AWS/GCP envelope encryption, the
    EventStoreDB/Verraes "Throw Away the Key" pattern) uses a genuinely separate, independently
    stored DEK per redaction unit, because that is what makes "delete one key, lose exactly one
    record" possible at all.

    The payload travels with the log, encrypted. The wrapped DEK lives here, in a keystore keyed
    by [event_id] -- structurally {b outside} anything the envelope's own
    {!Riptide.Envelope.content_hash} covers. Redaction is therefore exactly one operation, on one
    keystore row, and the hash chain never changes and never even observes it.

    {b What [event_id] means here, and what it deliberately does not.} It is an opaque keystore
    key, supplied by whoever encrypts, and it is {b not} the encrypted record's own
    {!Riptide.Envelope.event_id}. It cannot be: an envelope's [event_id] is its
    {!Riptide.Envelope.content_hash}, which covers the ciphertext {e and} the [predecessor_hash]
    and [sequence] that only exist once the record's position in the committed log is settled --
    so it is not knowable at the moment encryption has to happen (strictly before the payload
    enters the log, since that hash covers the payload). {!Riptide_batch_commit.Batch_commit}
    resolves this by deriving a stable, collision-free key from the batch's own idempotency key and
    the write's index within it; see {!Riptide_batch_commit.Batch_commit.redaction_event_id}. Any
    other caller may key records however it likes, provided the key is unique per record and
    stable for that record's lifetime.

    {b Concurrency.} A [t] is as safe to share as the underlying
    {!Riptide_storage.File_kv_store.t} and no safer; it holds no mutable state of its own. Two
    concurrent {!encrypt_for_storage} calls for the {e same} [event_id] race in the keystore
    exactly as two concurrent [put]s would -- one DEK wins, and the ciphertext returned by the
    loser becomes undecryptable. Callers must not reuse an [event_id] for two different records. *)

type t

val create : kv:Riptide_storage.File_kv_store.t -> kek:Kek.t -> t
(** [create ~kv ~kek] builds a keystore over [kv], wrapping every DEK it stores under [kek].

    [kv] holds only wrapped DEKs -- material that is useless without [kek] -- so it does not itself
    need to be a secret store. It does need real, durable per-key deletion, which is precisely why
    Task 2 introduced {!Riptide_storage.Kv_store_intf.S} rather than reusing
    {!Riptide_storage.Storage_intf.S}'s bounded-ring WAL shape: a redaction that leaves the DEK
    recoverable on disk is not a redaction. *)

val encrypt_for_storage : t -> event_id:string -> Riptide.Value.value -> string
(** [encrypt_for_storage t ~event_id v] generates a fresh DEK, encrypts
    {!Riptide.Value.canonical_encode}[ v] under it, durably stores that DEK wrapped under the KEK
    (and bound to [event_id] as GCM additional authenticated data) at key [event_id], and returns
    the ciphertext.

    {b Ordering is deliberate and load-bearing}: the wrapped DEK is durably stored {e before} this
    function returns, hence before the caller can possibly write the returned ciphertext anywhere.
    The reverse order would make a crash in between permanently destroy a record nobody asked to
    redact. In this order a crash leaves at worst an orphan DEK for a ciphertext that was never
    written -- garbage, not data loss.

    Overwrites any DEK already stored at [event_id]. A caller that reuses an [event_id] for a
    second record therefore destroys the first; see this module's header on [event_id] uniqueness. *)

val decrypt : t -> event_id:string -> string -> Riptide.Value.value option
(** [decrypt t ~event_id ciphertext] looks up [event_id]'s wrapped DEK, unwraps it under the KEK,
    and decrypts [ciphertext] with it.

    [None] -- never an exception -- for every failure, which are deliberately indistinguishable
    from one another: the record was redacted (no keystore entry), the keystore entry is corrupt or
    was tampered with, [event_id] is the wrong one for this ciphertext (the AAD binding rejects
    it), the KEK is the wrong one, the ciphertext was tampered with, or the recovered plaintext is
    not a well-formed {!Riptide.Value.canonical_encode} encoding. "Redacted" and "unrecoverable for
    some other reason" are the same observable outcome by design -- a caller learning which one it
    was would be learning something about a payload that is supposed to be gone. *)

val redact : t -> event_id:string -> unit
(** [redact t ~event_id] durably deletes [event_id]'s wrapped DEK. This is the whole of redaction:
    the ciphertext, the envelope, and every content hash in the chain are left untouched, and the
    payload becomes unrecoverable because the only key that could ever have opened it no longer
    exists. A no-op if [event_id] was never stored or was already redacted. *)

val payload_of_ciphertext : string -> Riptide.Value.value
(** [payload_of_ciphertext ct] is the canonical way this codebase carries ciphertext inside a
    {!Riptide.Value.value}: [Value.Scalar (Value.Bytes ct)]. Exposed so callers (and tests) can
    build the exact envelope payload {!encrypt_value} produces without re-deciding the wrapping. *)

val encrypt_value : t -> event_id:string -> Riptide.Value.value -> Riptide.Value.value
(** [encrypt_value t ~event_id v] is {!encrypt_for_storage} with its result wrapped by
    {!payload_of_ciphertext} -- the shape an envelope payload actually needs. This is the function
    a {!Riptide_batch_commit.Batch_commit.encryption_sink} is built from. *)

val decrypt_value : t -> event_id:string -> Riptide.Value.value -> Riptide.Value.value option
(** [decrypt_value t ~event_id payload] is the inverse of {!encrypt_value}, applied to an
    envelope's own [payload] field. [None] for everything {!decrypt} returns [None] for, and also
    if [payload] is not shaped like {!payload_of_ciphertext}'s output at all (e.g. a plaintext
    payload from a write that never opted into encryption). *)
