(* spec/golden/generate.ml *)
open Riptide

let hex_encode (s : string) : string =
  String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let print_vector name (v : Value.value) =
  Printf.printf "%s\t%s\t%s\n" name
    (Value.hash_to_hex (Value.content_hash v))
    (hex_encode (Value.canonical_encode v))

let () =
  print_vector "empty_string" (Value.Scalar (Value.String ""));
  print_vector "int_zero" (Value.Scalar (Value.Int 0L));
  print_vector "int_negative_one" (Value.Scalar (Value.Int (-1L)));
  print_vector "bool_true" (Value.Scalar (Value.Bool true));
  print_vector "empty_record" (Value.Record []);
  print_vector "empty_sequence" (Value.Sequence []);
  print_vector "nested_sum"
    (Value.Sum ("some", Value.Record [ ("x", Value.Scalar (Value.Int 42L)) ]));
  let genesis_envelope : Envelope.envelope =
    {
      actor = "genesis-actor";
      causation = Envelope.genesis_marker;
      correlation = Envelope.genesis_marker;
      predecessor_hash = Envelope.genesis_marker;
      sequence = 1L;
      payload = Value.Scalar (Value.String "genesis");
    }
  in
  Printf.printf "genesis_envelope\t%s\n" (Value.hash_to_hex (Envelope.content_hash genesis_envelope))
