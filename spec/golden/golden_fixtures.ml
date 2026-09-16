(* spec/golden/golden_fixtures.ml

   The fixed list of golden-vector inputs. Both spec/golden/generate.ml
   (which emits spec/golden/vectors.txt) and test/test_golden.ml (which
   re-derives every vector and checks it against the committed file) read
   from this single shared list, so the generator and the regression test
   can never independently drift out of sync (M2). *)

open Riptide

(* Plain Value.value vectors, one line each in vectors.txt. Covers every
   constructor tag in the value universe at least once (L6): Bool, Int
   (zero, negative, and a large positive one), Float, String (empty and
   non-empty), Bytes, Record (empty and multi-field), Sum, Sequence (empty
   and multi-element), and Map. *)
let values : (string * Value.value) list =
  [
    ("empty_string", Value.Scalar (Value.String ""));
    ("int_zero", Value.Scalar (Value.Int 0L));
    ("int_negative_one", Value.Scalar (Value.Int (-1L)));
    ("bool_true", Value.Scalar (Value.Bool true));
    ("empty_record", Value.Record []);
    ("empty_sequence", Value.Sequence []);
    ("nested_sum", Value.Sum ("some", Value.Record [ ("x", Value.Scalar (Value.Int 42L)) ]));
    ("float_pi", Value.Scalar (Value.Float 3.14159));
    ("float_negative_zero", Value.Scalar (Value.Float (-0.0)));
    ("bytes_sample", Value.Scalar (Value.Bytes "\x00\x01\xff\x02"));
    ( "map_sample",
      Value.Map
        [
          (Value.Scalar (Value.String "k1"), Value.Scalar (Value.Int 1L));
          (Value.Scalar (Value.String "k2"), Value.Scalar (Value.Int 2L));
        ] );
    ( "record_multi_field",
      Value.Record
        [
          ("a", Value.Scalar (Value.Int 1L));
          ("b", Value.Scalar (Value.String "x"));
          ("c", Value.Scalar (Value.Bool false));
        ] );
    ( "sequence_multi",
      Value.Sequence
        [ Value.Scalar (Value.Int 1L); Value.Scalar (Value.Int 2L); Value.Scalar (Value.Int 3L) ] );
  ]

(* The one envelope vector. Its canonical bytes/hash are derived via
   Envelope.to_value so the golden file also pins the envelope's Record
   wire shape (field names, field count, field order after canonicalization),
   not just the plain value encoding. *)
let genesis_envelope : Envelope.envelope =
  {
    actor = "genesis-actor";
    causation = Envelope.genesis_marker;
    correlation = Envelope.genesis_marker;
    predecessor_hash = Envelope.genesis_marker;
    sequence = 1L;
    payload = Value.Scalar (Value.String "genesis");
  }

let envelope_vector_name = "genesis_envelope"
