open Riptide_module

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let test_invoke_calls_the_guests_handle_and_observes_its_log_call () =
  let logged = ref [] in
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write = (fun _ -> Ok ());
      log = (fun s -> logged := s :: !logged);
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/echo.wat") ~host
  in
  (match Loader.invoke m ~entrypoint:"handle" ~arg:Bytes.empty with
  | Ok _ -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check (list string)) "guest logged once" [ "hello" ] !logged

let test_a_runaway_module_is_contained_not_crashing_the_host () =
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write = (fun _ -> Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/runaway.wat") ~host
  in
  match Loader.invoke m ~entrypoint:"handle" ~arg:Bytes.empty with
  | Ok _ -> Alcotest.fail "expected containment, not success"
  | Error e -> Alcotest.(check bool) "fuel exhaustion is reported, not a host crash" true (String.length e > 0)

let test_read_materialized_relays_a_known_value_back_to_the_guest () =
  let seen_keys = ref [] in
  let host =
    {
      Loader.read_materialized =
        (fun ~merge_key ->
          seen_keys := merge_key :: !seen_keys;
          if merge_key = "known" then Some (Bytes.of_string "VALUE123") else None);
      propose_write = (fun _ -> Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/read_materialized.wat")
      ~host
  in
  (* arg byte 0 = '\000' selects the "known" key in this fixture's own convention. *)
  match Loader.invoke m ~entrypoint:"handle" ~arg:(Bytes.make 1 '\000') with
  | Error e -> Alcotest.fail e
  | Ok result ->
    Alcotest.(check string) "the host's value round-tripped through the guest and back out"
      "VALUE123" (Bytes.to_string result);
    Alcotest.(check (list string)) "the host observed the real key the guest asked for" [ "known" ]
      !seen_keys

let test_read_materialized_relays_none_for_a_missing_key () =
  let seen_keys = ref [] in
  let host =
    {
      Loader.read_materialized =
        (fun ~merge_key ->
          seen_keys := merge_key :: !seen_keys;
          if merge_key = "known" then Some (Bytes.of_string "VALUE123") else None);
      propose_write = (fun _ -> Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/read_materialized.wat")
      ~host
  in
  (* any nonzero arg byte 0 selects the "missing" key in this fixture's own convention. *)
  match Loader.invoke m ~entrypoint:"handle" ~arg:(Bytes.make 1 '\001') with
  | Error e -> Alcotest.fail e
  | Ok result ->
    Alcotest.(check string) "None comes back out as zero bytes, not a stale/garbage value" ""
      (Bytes.to_string result);
    Alcotest.(check (list string)) "the host observed the real key the guest asked for"
      [ "missing" ] !seen_keys

let test_propose_write_relays_the_guests_bytes_to_the_host_and_returns_success () =
  let seen_payloads = ref [] in
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write =
        (fun payload ->
          seen_payloads := Bytes.to_string payload :: !seen_payloads;
          if Bytes.to_string payload = "reject-me" then Error "nope" else Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/propose_write.wat")
      ~host
  in
  match Loader.invoke m ~entrypoint:"handle" ~arg:(Bytes.of_string "allow-me") with
  | Error e -> Alcotest.fail e
  | Ok result ->
    Alcotest.(check string) "the guest observed a success status byte (0) back from the host"
      "\000" (Bytes.to_string result);
    Alcotest.(check (list string))
      "the host received the guest's own exact payload bytes, unmodified" [ "allow-me" ]
      !seen_payloads

let test_propose_write_relays_the_hosts_denial_back_to_the_guest () =
  let seen_payloads = ref [] in
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write =
        (fun payload ->
          seen_payloads := Bytes.to_string payload :: !seen_payloads;
          if Bytes.to_string payload = "reject-me" then Error "nope" else Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/propose_write.wat")
      ~host
  in
  match Loader.invoke m ~entrypoint:"handle" ~arg:(Bytes.of_string "reject-me") with
  | Error e -> Alcotest.fail e
  | Ok result ->
    Alcotest.(check string) "the guest observed a denial status byte (1) back from the host"
      "\001" (Bytes.to_string result);
    Alcotest.(check (list string)) "the host still received the exact rejected payload"
      [ "reject-me" ] !seen_payloads

let no_op_host () =
  {
    Loader.read_materialized = (fun ~merge_key:_ -> None);
    propose_write = (fun _ -> Ok ());
    log = (fun _ -> ());
  }

let test_instantiate_rejects_a_module_declaring_a_memory_maximum_over_the_cap () =
  Alcotest.check_raises
    "an over-large self-declared memory maximum is rejected at load time, not silently honored"
    (Failure
       "Loader.instantiate: guest module's own declared memory maximum (65536 pages / 4294967296 \
        bytes) exceeds this loader's cap (1024 pages / 67108864 bytes)") (fun () ->
      ignore
        (Loader.instantiate ~tier:Loader.Sfi
           ~module_bytes:(read_file "fixtures/oversized_memory.wat") ~host:(no_op_host ())))

let test_instantiate_rejects_a_module_declaring_no_memory_maximum_at_all () =
  Alcotest.check_raises
    "an unbounded (no declared maximum) memory is rejected too, not just an over-large bounded one"
    (Failure
       "Loader.instantiate: guest module declares its memory with no maximum at all (unbounded \
        growth) -- a declared maximum of at most 1024 pages (67108864 bytes) is required") (fun () ->
      ignore
        (Loader.instantiate ~tier:Loader.Sfi
           ~module_bytes:(read_file "fixtures/unbounded_memory.wat") ~host:(no_op_host ())))

let test_run_contained_reaps_and_closes_fds_even_when_the_child_dies_mid_message () =
  let result, child_pid, req_r, resp_w = Loader.For_testing.simulate_child_death_mid_message () in
  (match result with
  | Ok _ ->
    Alcotest.fail
      "expected a containment-failure Error (invoke's own contract: never raises), not Ok, for a \
       child that never completed its message"
  | Error e ->
    Alcotest.(check bool) "a real, non-empty error is returned instead of an uncaught exception"
      true
      (String.length e > 0));
  (* A genuinely reaped process is fully gone: kill(pid, 0) fails with ESRCH. An unreaped
     zombie is still visible to the process table and kill(pid, 0) on it still SUCCEEDS. *)
  (match Unix.kill child_pid 0 with
  | () -> Alcotest.fail "the forked child was left as a zombie -- not reaped"
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ()
  | exception exn -> raise exn);
  let confirm_closed name fd =
    match Unix.close fd with
    | () -> Alcotest.fail (Printf.sprintf "%s was leaked open, not closed" name)
    | exception Unix.Unix_error (Unix.EBADF, _, _) -> ()
    | exception exn -> raise exn
  in
  confirm_closed "req_r" req_r;
  confirm_closed "resp_w" resp_w

let test_microvm_tier_raises_a_clear_not_implemented_error () =
  Alcotest.check_raises "microvm tier is designed, not built"
    (Failure "Loader.instantiate: Microvm tier is not yet implemented (Task 8's own job)") (fun () ->
      ignore
        (Loader.instantiate ~tier:Loader.Microvm ~module_bytes:(read_file "fixtures/echo.wat")
           ~host:
             {
               Loader.read_materialized = (fun ~merge_key:_ -> None);
               propose_write = (fun _ -> Ok ());
               log = ignore;
             }))

let tests =
  [
    ( "Loader.invoke calls the guest's handle and observes its log call",
      `Quick,
      test_invoke_calls_the_guests_handle_and_observes_its_log_call );
    ( "Loader.invoke contains a runaway module instead of crashing the host",
      `Quick,
      test_a_runaway_module_is_contained_not_crashing_the_host );
    ( "Loader.invoke relays a known read_materialized value back to the guest",
      `Quick,
      test_read_materialized_relays_a_known_value_back_to_the_guest );
    ( "Loader.invoke relays None for a missing read_materialized key",
      `Quick,
      test_read_materialized_relays_none_for_a_missing_key );
    ( "Loader.invoke relays the guest's propose_write bytes to the host and returns success",
      `Quick,
      test_propose_write_relays_the_guests_bytes_to_the_host_and_returns_success );
    ( "Loader.invoke relays the host's propose_write denial back to the guest",
      `Quick,
      test_propose_write_relays_the_hosts_denial_back_to_the_guest );
    ( "Loader.instantiate rejects a module declaring a memory maximum over the cap",
      `Quick,
      test_instantiate_rejects_a_module_declaring_a_memory_maximum_over_the_cap );
    ( "Loader.instantiate rejects a module declaring no memory maximum at all",
      `Quick,
      test_instantiate_rejects_a_module_declaring_no_memory_maximum_at_all );
    ( "run_contained reaps the child and closes both pipe fds even when it dies mid-message",
      `Quick,
      test_run_contained_reaps_and_closes_fds_even_when_the_child_dies_mid_message );
    ( "Loader.instantiate raises a clear not-implemented error for the Microvm tier",
      `Quick,
      test_microvm_tier_raises_a_clear_not_implemented_error );
  ]
