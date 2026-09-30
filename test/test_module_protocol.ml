open Riptide_module.Protocol

let test_create_rejects_a_transition_naming_an_unknown_state () =
  Alcotest.check_raises "unknown to_state is rejected"
    (Invalid_argument "Protocol.create: transition to unknown state \"missing\"") (fun () ->
      ignore
        (create ~states:[ "init" ] ~initial:"init"
           ~transitions:[ { from_state = "init"; on_call = "handle"; to_state = "missing" } ]))

let test_create_rejects_a_nondeterministic_protocol () =
  Alcotest.check_raises "two transitions for the same (state, call) pair is rejected"
    (Invalid_argument
       "Protocol.create: state \"init\" already has a transition on call \"handle\"") (fun () ->
      ignore
        (create ~states:[ "init"; "a"; "b" ] ~initial:"init"
           ~transitions:
             [
               { from_state = "init"; on_call = "handle"; to_state = "a" };
               { from_state = "init"; on_call = "handle"; to_state = "b" };
             ]))

let test_step_follows_a_valid_transition () =
  let p =
    create ~states:[ "init"; "ready" ] ~initial:"init"
      ~transitions:[ { from_state = "init"; on_call = "init"; to_state = "ready" } ]
  in
  match step (start p) ~call:"init" with
  | Ok c -> Alcotest.(check string) "moved to ready" "ready" (current_state c)
  | Error e -> Alcotest.fail e

let test_step_rejects_a_call_invalid_from_the_current_state () =
  let p =
    create ~states:[ "init"; "ready" ] ~initial:"init"
      ~transitions:[ { from_state = "init"; on_call = "init"; to_state = "ready" } ]
  in
  match step (start p) ~call:"handle" with
  | Ok _ -> Alcotest.fail "expected rejection"
  | Error e ->
    Alcotest.(check bool) "names the illegal call and the current state" true
      (String.length e > 0)

let tests =
  [
    ("Protocol.create rejects unknown to_state", `Quick, test_create_rejects_a_transition_naming_an_unknown_state);
    ("Protocol.create rejects nondeterministic protocol", `Quick, test_create_rejects_a_nondeterministic_protocol);
    ("Protocol.step follows valid transition", `Quick, test_step_follows_a_valid_transition);
    ("Protocol.step rejects invalid call", `Quick, test_step_rejects_a_call_invalid_from_the_current_state);
  ]
