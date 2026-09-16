(* test/test_golden.ml *)
open Riptide

let hex_encode (s : string) : string =
  String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

(* Path is relative to this test's own working directory
   (_build/default/test/, or its sandboxed equivalent under
   --sandbox=copy). test/dune declares
   "(deps ../spec/golden/vectors.txt)" using the same relative path, which
   is what makes dune (a) treat this test as stale whenever
   spec/golden/vectors.txt changes, without needing --force, and (b) copy
   the file into the sandbox at this same relative location when building
   with --sandbox=copy. Verified empirically against this dune's actual
   behavior (3.24.2): both `dune test` after corrupting the file and
   `dune build @runtest --force --sandbox=copy` work correctly with this
   exact path + deps combination. *)
let golden_file_path = "../spec/golden/vectors.txt"

let read_golden_file () =
  let ic = open_in golden_file_path in
  let rec read_lines acc =
    match input_line ic with
    | line -> read_lines (line :: acc)
    | exception End_of_file -> List.rev acc
  in
  let lines = read_lines [] in
  close_in ic;
  lines

(* name -> (hash_hex, bytes_hex) *)
let parse_golden_lines lines =
  List.map
    (fun line ->
       match String.split_on_char '\t' line with
       | [ name; hash_hex; bytes_hex ] -> (name, (hash_hex, Some bytes_hex))
       | [ name; hash_hex ] -> (name, (hash_hex, None))
       | _ -> failwith (Printf.sprintf "malformed golden line: %S" line))
    lines

(* Re-derives every vector in Golden_fixtures.values (all of them, not a
   subset) plus the one envelope vector, and checks both the hash column
   and the canonical-bytes column against the committed file - not just a
   hash substring match. Driven by the same shared Golden_fixtures list
   spec/golden/generate.ml uses, so the generator and this test can never
   independently drift (M2). *)
let test_golden_vectors_reproduce () =
  let golden = parse_golden_lines (read_golden_file ()) in
  let check_vector name (v : Value.value) =
    let expected_hash, expected_bytes =
      match List.assoc_opt name golden with
      | Some pair -> pair
      | None -> failwith (Printf.sprintf "no golden entry named %S in %s" name golden_file_path)
    in
    let actual_hash = Value.hash_to_hex (Value.content_hash v) in
    let actual_bytes = hex_encode (Value.canonical_encode v) in
    Alcotest.(check string) (Printf.sprintf "%s: hash matches golden file" name) expected_hash actual_hash;
    match expected_bytes with
    | Some expected_bytes ->
      Alcotest.(check string) (Printf.sprintf "%s: canonical bytes match golden file" name) expected_bytes
        actual_bytes
    | None -> ()
  in
  List.iter (fun (name, v) -> check_vector name v) Golden_fixtures.values;
  check_vector Golden_fixtures.envelope_vector_name (Envelope.to_value Golden_fixtures.genesis_envelope);
  (* Also confirm the golden file has no stray/unexpected entries left over
     from a previous shape of the fixed input list - the two must agree
     exactly on which vectors exist, not just agree on the vectors both
     happen to mention. *)
  let expected_names =
    Golden_fixtures.envelope_vector_name :: List.map fst Golden_fixtures.values
  in
  let golden_names = List.map fst golden in
  Alcotest.(check (list string)) "golden file has exactly the vectors Golden_fixtures declares"
    (List.sort compare expected_names) (List.sort compare golden_names)

let tests = [ ("golden vectors reproduce", `Quick, test_golden_vectors_reproduce) ]
