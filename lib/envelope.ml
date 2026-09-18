type actor_id = string
type event_id = Value.hash

type envelope = {
  actor : actor_id;
  causation : event_id;
  correlation : event_id;
  predecessor_hash : Value.hash;
  sequence : int64;
  payload : Value.value;
}

let genesis_marker = String.make 32 '\x00'

let to_value (e : envelope) : Value.value =
  Value.Record
    [
      ("actor", Value.Scalar (Value.String e.actor));
      ("causation", Value.Scalar (Value.Bytes e.causation));
      ("correlation", Value.Scalar (Value.Bytes e.correlation));
      ("predecessor_hash", Value.Scalar (Value.Bytes e.predecessor_hash));
      ("sequence", Value.Scalar (Value.Int e.sequence));
      ("payload", e.payload);
    ]

(* Domain separation: an envelope is hashed as a Value.Sum wrapping its
   Record shape, not as a bare Record, so a crafted payload Value.value
   shaped like a Record with the envelope's exact field set can never
   collide with a real event_id. Sum and Record have distinct leading
   tag bytes in Value.canonical_encode (tag_sum vs tag_record), so this
   holds by construction, not by convention - see
   docs/superpowers/plans/2026-09-18-event-id-domain-separation.md. *)
let domain_tag = "Envelope"

let content_hash e = Value.content_hash (Value.Sum (domain_tag, to_value e))
