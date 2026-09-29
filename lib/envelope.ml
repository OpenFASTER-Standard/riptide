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
   Record shape, not as a bare Record. Collision between this hash space
   and a plain payload Value.value's hash space is possible only for a
   payload of the exact literal shape Sum ("Envelope", to_value e) - an
   intentional, deliberately-tested equivalence, not a defect. A crafted
   bare Record with the envelope's field set cannot collide. Sum and Record
   have distinct leading tag bytes in Value.canonical_encode (tag_sum vs
   tag_record), so this domain separation holds by construction, not by
   convention - see docs/superpowers/plans/2026-09-18-event-id-domain-
   separation.md. *)
let domain_tag = "Envelope"

let content_hash e = Value.content_hash (Value.Sum (domain_tag, to_value e))
