let () =
  Alcotest.run "riptide"
    [
      ("value", Test_value.tests);
      ("envelope", Test_envelope.tests);
      ("log", Test_log.tests);
      ("golden", Test_golden.tests);
      ("sim_prng", Test_sim_prng.tests);
      ("sim_network", Test_sim_network.tests);
      ("sim_faults", Test_sim_faults.tests);
      ("sim_workload", Test_sim_workload.tests);
    ]
