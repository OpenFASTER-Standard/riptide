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
      ("causation", Value.Scalar (Value.Bytes (Bytes.of_string e.causation)));
      ("correlation", Value.Scalar (Value.Bytes (Bytes.of_string e.correlation)));
      ("predecessor_hash", Value.Scalar (Value.Bytes (Bytes.of_string e.predecessor_hash)));
      ("sequence", Value.Scalar (Value.Int e.sequence));
      ("payload", e.payload);
    ]

let content_hash e = Value.content_hash (to_value e)
