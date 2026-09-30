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
    ( "Loader.instantiate raises a clear not-implemented error for the Microvm tier",
      `Quick,
      test_microvm_tier_raises_a_clear_not_implemented_error );
  ]
