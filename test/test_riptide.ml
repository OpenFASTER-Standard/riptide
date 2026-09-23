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
   tick closes that gap: each subsequent hang gets its own fresh timeout.

   TASK 11 CORRECTION: re-arming on every tick did NOT actually make this a per-test timeout, and
   the difference stopped being academic the moment this suite gained a test that does real disk
   I/O. [Unix.setitimer] with an interval fires at a fixed cadence from suite start (t=5s, t=10s,
   ...) regardless of test boundaries, so what it really imposed was a SUITE-WIDE 5s deadline: a
   healthy suite that merely took longer than 5s in total would have SIGALRM land in whichever test
   happened to be running at that instant and fail it, with a message blaming that innocent test
   for a busy-poll livelock. Nobody hit it because the whole suite ran in ~1.2s; test_dst_scenarios
   (real File_storage clusters under Eio_main) takes it to ~3.6s, close enough to 5s that a loaded
   or slower CI machine would have started failing a random test intermittently -- the worst
   possible failure mode for a watchdog, since it discredits the suite rather than a bug.

   The fix is to give every test its own fresh budget explicitly ([with_watchdog] below re-arms the
   timer as each test starts), which is what "each subsequent hang gets its own fresh timeout"
   above was always trying to say. The interval is kept as well, so a hang INSIDE one test still
   gets re-fired backstops if the first exception is somehow swallowed. *)
exception Suite_timeout

let timeout_seconds = 15.
(* Per test, not per suite (see above). Raised from 5s at the same time it became per-test: the
   File_storage-backed cluster tests do real io_uring I/O whose duration depends on the machine,
   and this bound exists to distinguish "hung forever" from "slow", not to police performance. *)

let arm_watchdog () =
  ignore
    (Unix.setitimer Unix.ITIMER_REAL
       { Unix.it_interval = timeout_seconds; it_value = timeout_seconds })

(* Wraps every test in every suite, in one place, so no individual test file has to know this
   exists and no future test can forget to opt in. *)
let with_watchdog (name, speed, f) =
  ( name,
    speed,
    fun () ->
      arm_watchdog ();
      f () )

let suite (name, tests) = (name, List.map with_watchdog tests)

let () =
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
  arm_watchdog ();
  Alcotest.run "riptide"
  @@ List.map suite
       [
         ("value", Test_value.tests);
         ("envelope", Test_envelope.tests);
         ("log", Test_log.tests);
         ("golden", Test_golden.tests);
         ("lattice", Test_lattice.tests);
         ("batch_commit", Test_batch_commit.tests);
         ("batch_commit_cluster", Test_batch_commit_cluster.tests);
         ("batch_commit_materialize", Test_batch_commit_materialize.tests);
         ("dek", Test_dek.tests);
         ("redaction", Test_redaction.tests);
         ("sim_prng", Test_sim_prng.tests);
         ("sim_network", Test_sim_network.tests);
         ("sim_faults", Test_sim_faults.tests);
         ("sim_workload", Test_sim_workload.tests);
         ("file_storage", Test_file_storage.tests);
         ("file_kv_store", Test_file_kv_store.tests);
         ("materializer", Test_materializer.tests);
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
         ("dst_cluster", Test_dst_cluster.tests);
         ("dst_scenarios", Test_dst_scenarios.tests);
       ]
