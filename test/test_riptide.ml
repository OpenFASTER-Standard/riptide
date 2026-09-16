let () =
  Alcotest.run "riptide"
    [ ("value", Test_value.tests); ("envelope", Test_envelope.tests); ("log", Test_log.tests) ]
