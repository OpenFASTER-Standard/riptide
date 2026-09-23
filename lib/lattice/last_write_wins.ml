(** A register that keeps the value with the highest timestamp, breaking
    exact-timestamp ties deterministically by the value's own content hash
    — so [join] stays commutative even when two writers pick the same
    timestamp. [bottom] carries timestamp [Int64.min_int] so any real write
    dominates it. *)
type t = { value : Riptide.Value.value; timestamp : int64 }

let bottom = { value = Riptide.Value.Sequence []; timestamp = Int64.min_int }

let join a b =
  if a.timestamp <> b.timestamp then (if a.timestamp > b.timestamp then a else b)
  else if Riptide.Value.content_hash a.value >= Riptide.Value.content_hash b.value then a
  else b
