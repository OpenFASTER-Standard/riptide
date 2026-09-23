(* Suite-wide wall-clock timeout backstop.

   [Eio_mock.Backend]'s own deadlock detector only fires for a fiber that genuinely *suspends* on
   an effect. A busy-poll loop (e.g. a [receive_nonblocking] retry driven by [Eio.Fiber.yield]
   rather than a bounded, one-shot drain) is always "runnable" as far as the scheduler is
   concerned and never looks like a deadlock, so it spins forever with no exception and no CI
   timeout backstop - see the M1 finding in
   `.superpowers/sdd/2026-09-16-dst-proof-of-concept/final-fix-review.md`, which reproduced
   exactly this: reintroducing that busy-poll shape into `Workload`'s receiver loop made
   `dune test` hang 30s+ with no output. `lib/sim/workload.ml`'s current Phase 1/Phase 2 design
   deliberately avoids that shape (Phase 2's drain never waits for a delivery that might still be
   coming - Phase 1 has already fully resolved the network first), so nothing in the suite hangs
   today. But nothing enforced that structurally, so a future change reintroducing a genuine
   busy-poll wait would previously hang forever with zero signal.

   This alarm-based watchdog is that backstop: any hang in the suite - from this bug class or any
   other - now fails fast with a real, catchable exception instead of hanging indefinitely.
   [timeout_seconds] is generous relative to the real suite (well under 1s as of this writing) but
   far below "hangs forever."

   Deliberately a *repeating* interval timer ([Unix.setitimer], not the one-shot [Unix.alarm]):
   the first version of this fix used [Unix.alarm], which fires exactly once. That is enough to
   catch a *single* hung test - Alcotest catches the resulting exception, marks that one test
   failed, and moves on - but if more than one test in the suite hangs (verified live: temporarily
   reintroducing the busy-poll bug broke every `sim_workload` test built on [run_toy_cluster], not
   just the [drop_probability = 1.0] regression test alone), the alarm has already been consumed
   and every later hang has no backstop left, so the suite still hangs overall. Re-arming on every
   tick closes that gap: each subsequent hang gets its own fresh timeout. *)
exception Suite_timeout

let () =
  let timeout_seconds = 5. in
  Sys.set_signal Sys.sigalrm
    (Sys.Signal_handle
       (fun _ ->
         Printf.eprintf
           "\n\
            [test_riptide] a test exceeded a %.0fs wall-clock timeout - likely a busy-poll \
            livelock (Eio_mock.Backend cannot detect a fiber that never truly suspends); see M1 \
            in final-fix-review.md.\n\
            %!"
           timeout_seconds;
         raise Suite_timeout));
  ignore
    (Unix.setitimer Unix.ITIMER_REAL
       { Unix.it_interval = timeout_seconds; it_value = timeout_seconds });
  Alcotest.run "riptide"
    [
      ("value", Test_value.tests);
      ("envelope", Test_envelope.tests);
      ("log", Test_log.tests);
      ("golden", Test_golden.tests);
      ("batch_commit", Test_batch_commit.tests);
      ("batch_commit_cluster", Test_batch_commit_cluster.tests);
      ("sim_prng", Test_sim_prng.tests);
      ("sim_network", Test_sim_network.tests);
      ("sim_faults", Test_sim_faults.tests);
      ("sim_workload", Test_sim_workload.tests);
      ("file_storage", Test_file_storage.tests);
      ("storage_shared_file_storage", Test_storage_shared.file_storage_tests);
      ("storage_shared_fault_injecting_storage", Test_storage_shared.fault_injecting_storage_tests);
      ("storage_shared_memory_storage", Test_storage_shared.memory_storage_tests);
      ("fault_injecting_storage", Test_fault_injecting_storage.tests);
      ("transport_tcp", Test_transport_tcp.tests);
      ("transport_shared_sim", Test_transport_shared.sim_tests);
      ("transport_shared_tcp", Test_transport_shared.tcp_tests);
      ("vsr_message", Test_vsr_message.tests);
      ("vsr_replica_log", Test_vsr_replica_log.tests);
      ("vsr_replica", Test_vsr_replica.tests);
      ("vsr_replica_cluster", Test_vsr_replica_cluster.tests);
      ("vsr_replica_view_change", Test_vsr_replica_view_change.tests);
      ("vsr_replica_recovery", Test_vsr_replica_recovery.tests);
    ]
