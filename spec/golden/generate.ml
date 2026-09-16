(* spec/golden/generate.ml *)
open Riptide

let hex_encode (s : string) : string =
  String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let print_vector name (v : Value.value) =
  Printf.printf "%s\t%s\t%s\n" name
    (Value.hash_to_hex (Value.content_hash v))
    (hex_encode (Value.canonical_encode v))

let () =
  List.iter (fun (name, v) -> print_vector name v) Golden_fixtures.values;
  print_vector Golden_fixtures.envelope_vector_name
    (Envelope.to_value Golden_fixtures.genesis_envelope)
