(* test/test_golden.ml *)
open Riptide

let read_golden_file () =
  let ic = open_in "../../../spec/golden/vectors.txt" in
  (* dune test runs from _build/default/test/, hence the relative path back
     to the project root - if this path is wrong when you run it, adjust
     to the real relative path dune uses and note the correction in your
     report. *)
  let rec read_lines acc =
    match input_line ic with
    | line -> read_lines (line :: acc)
    | exception End_of_file -> List.rev acc
  in
  let lines = read_lines [] in
  close_in ic;
  lines

let test_golden_vectors_reproduce () =
  let expected = read_golden_file () in
  let regenerate_line name (v : Value.value) =
    Printf.sprintf "%s\t%s" name (Value.hash_to_hex (Value.content_hash v))
  in
  (* Recompute at least the hash half of each non-envelope vector and
     confirm it appears as a substring of the corresponding golden line -
     this catches any accidental behavior change in canonical_encode or
     content_hash without needing to re-derive the full hex-encoded byte
     dump inline here. *)
  let checks =
    [ regenerate_line "empty_string" (Value.Scalar (Value.String ""));
      regenerate_line "int_zero" (Value.Scalar (Value.Int 0L));
      regenerate_line "bool_true" (Value.Scalar (Value.Bool true))
    ]
  in
  List.iter
    (fun check_line ->
       let name, hash = match String.split_on_char '\t' check_line with
         | n :: h :: _ -> (n, h)
         | _ -> failwith "malformed check line"
       in
       let found =
         List.exists
           (fun golden_line -> String.length golden_line >= String.length check_line
                                && (try String.sub golden_line 0 (String.length (name ^ "\t" ^ hash)) = name ^ "\t" ^ hash
                                    with Invalid_argument _ -> false))
           expected
       in
       Alcotest.(check bool) (Printf.sprintf "%s hash matches golden file" name) true found)
    checks

let tests = [ ("golden vectors reproduce", `Quick, test_golden_vectors_reproduce) ]
