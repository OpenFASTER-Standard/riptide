(* test/test_vsr_replica_log.ml *)
open Riptide
open Riptide_vsr

let v s = Value.Scalar (Value.String s)

let test_append_in_order_is_readable () =
  let log = Replica_log.create () in
  Replica_log.append log ~op_number:1 (v "a");
  Replica_log.append log ~op_number:2 (v "b");
  Replica_log.append log ~op_number:3 (v "c");
  Alcotest.(check int) "length after three in-order appends" 3 (Replica_log.length log);
  Alcotest.(check bool) "get op_number:1 is the first appended value" true
    (Replica_log.get log ~op_number:1 = Some (v "a"));
  Alcotest.(check bool) "get op_number:2 is the second appended value" true
    (Replica_log.get log ~op_number:2 = Some (v "b"));
  Alcotest.(check bool) "get op_number:3 is the third appended value" true
    (Replica_log.get log ~op_number:3 = Some (v "c"))

let expect_out_of_order name ~op_number =
  ( name,
    `Quick,
    fun () ->
      let log = Replica_log.create () in
      Replica_log.append log ~op_number:1 (v "a");
      Replica_log.append log ~op_number:2 (v "b");
      match Replica_log.append log ~op_number (v "x") with
      | () -> Alcotest.failf "%s: expected Out_of_order_append, but append succeeded" name
      | exception Replica_log.Out_of_order_append { expected; got } ->
        Alcotest.(check int) (name ^ ": expected field") 3 expected;
        Alcotest.(check int) (name ^ ": got field") op_number got
      | exception exn -> Alcotest.failf "%s: expected Out_of_order_append, got %s" name (Printexc.to_string exn) )

let test_append_out_of_order_too_high () =
  let log = Replica_log.create () in
  match Replica_log.append log ~op_number:5 (v "x") with
  | () -> Alcotest.fail "expected Out_of_order_append when appending op_number 5 to an empty log"
  | exception Replica_log.Out_of_order_append { expected; got } ->
    Alcotest.(check int) "expected field" 1 expected;
    Alcotest.(check int) "got field" 5 got
  | exception exn -> Alcotest.failf "expected Out_of_order_append, got %s" (Printexc.to_string exn)

let test_get_out_of_range_returns_none () =
  let log = Replica_log.create () in
  Replica_log.append log ~op_number:1 (v "a");
  Alcotest.(check bool) "get op_number:0 is None" true (Replica_log.get log ~op_number:0 = None);
  Alcotest.(check bool) "get op_number:-1 is None" true (Replica_log.get log ~op_number:(-1) = None);
  Alcotest.(check bool) "get op_number:2 (beyond length) is None" true (Replica_log.get log ~op_number:2 = None);
  Alcotest.(check bool) "get on an empty log is None" true (Replica_log.get (Replica_log.create ()) ~op_number:1 = None)

let test_replace_with_discards_prior_entries () =
  let log = Replica_log.create () in
  Replica_log.append log ~op_number:1 (v "old-a");
  Replica_log.append log ~op_number:2 (v "old-b");
  Replica_log.replace_with log [ v "new-x"; v "new-y" ];
  Alcotest.(check int) "length reflects the replacement, not the prior entries" 2 (Replica_log.length log);
  Alcotest.(check bool) "get op_number:1 is the replacement's first entry" true
    (Replica_log.get log ~op_number:1 = Some (v "new-x"));
  Alcotest.(check bool) "get op_number:2 is the replacement's second entry" true
    (Replica_log.get log ~op_number:2 = Some (v "new-y"));
  Alcotest.(check bool) "get op_number:3 (beyond the new, shorter length) is None" true
    (Replica_log.get log ~op_number:3 = None);
  Alcotest.(check bool) "to_list reflects only the replacement" true
    (Replica_log.to_list log = [ v "new-x"; v "new-y" ])

let test_replace_with_empty_list () =
  let log = Replica_log.create () in
  Replica_log.append log ~op_number:1 (v "a");
  Replica_log.replace_with log [];
  Alcotest.(check int) "length is 0 after replacing with an empty log" 0 (Replica_log.length log);
  Alcotest.(check bool) "get op_number:1 is None after replacing with an empty log" true
    (Replica_log.get log ~op_number:1 = None)

let test_length_correct_through_appends_and_replace () =
  let log = Replica_log.create () in
  Alcotest.(check int) "length 0 on a fresh log" 0 (Replica_log.length log);
  Replica_log.append log ~op_number:1 (v "a");
  Alcotest.(check int) "length 1 after one append" 1 (Replica_log.length log);
  Replica_log.append log ~op_number:2 (v "b");
  Replica_log.append log ~op_number:3 (v "c");
  Alcotest.(check int) "length 3 after three appends" 3 (Replica_log.length log);
  Replica_log.replace_with log [ v "x"; v "y"; v "z"; v "w" ];
  Alcotest.(check int) "length 4 after replace_with a 4-entry log" 4 (Replica_log.length log);
  (* the log is still live after a replace: appends must resume at length + 1 *)
  Replica_log.append log ~op_number:5 (v "next");
  Alcotest.(check int) "length 5 after appending post-replace" 5 (Replica_log.length log);
  Alcotest.(check bool) "get op_number:5 is the post-replace append" true
    (Replica_log.get log ~op_number:5 = Some (v "next"))

let tests =
  [
    ("append in order succeeds and is readable via get", `Quick, test_append_in_order_is_readable);
    expect_out_of_order "append out of order: a gap" ~op_number:4;
    expect_out_of_order "append out of order: too low (duplicate of an already-applied op_number)" ~op_number:2;
    expect_out_of_order "append out of order: too low (op_number 1, already applied)" ~op_number:1;
    ("append out of order: too high on an empty log", `Quick, test_append_out_of_order_too_high);
    ("get on an out-of-range op_number returns None", `Quick, test_get_out_of_range_returns_none);
    ("replace_with discards prior entries", `Quick, test_replace_with_discards_prior_entries);
    ("replace_with an empty list empties the log", `Quick, test_replace_with_empty_list);
    ("length stays correct through appends and a replace", `Quick, test_length_correct_through_appends_and_replace);
  ]
