(** The event envelope: every fact this system ever records is one of
    these. Every field is mandatory at the type level — there is no
    [option] anywhere in this type, on purpose. Dropping actor identity
    between an HTTP-layer auth check and the persisted event was a real,
    confirmed defect in the old (v1) Riptide; this type makes that
    specific mistake impossible to construct. *)

type actor_id = string

(** An event's own {!content_hash} serves as its identity for causation/
    correlation linking. *)
type event_id = Value.hash

type envelope = {
  actor : actor_id;
  causation : event_id;
  correlation : event_id;
  predecessor_hash : Value.hash;
  sequence : int64;
  payload : Value.value;
}

(** Reserved sentinel (32 zero bytes) used only to seed [predecessor_hash],
    [causation], and [correlation] on the first envelope in a log. Never
    the real {!content_hash} of any actual envelope. *)
val genesis_marker : Value.hash

(** Expresses an envelope as a {!Value.value} (a [Record]), so envelope
    hashing reuses {!Value.canonical_encode} directly rather than a
    second, separately-specified encoding. *)
val to_value : envelope -> Value.value

val content_hash : envelope -> event_id
