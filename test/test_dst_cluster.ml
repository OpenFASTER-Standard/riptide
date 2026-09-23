(* test/test_dst_cluster.ml

   Task 9: proves [Riptide_dst.Cluster.run]'s two load-bearing reproducibility claims --

   - the same root seed always produces the same observable trace (the seed genuinely determines
     the whole run, deterministically), and
   - a different root seed CAN produce a different observable trace under real network faults
     (the seed is actually load-bearing -- i.e. not silently ignored, and the harness's fault
     injection is real, not a no-op).

   Both traces are REAL replicated/committed state, not raw local log length: [Replica.propose]
   appends to the proposer's own log synchronously, before anything is sent (see
   [Riptide_vsr.Replica.propose]'s own doc comment), so a proposer's own raw log length never
   depends on message delivery at all -- asserting on it alone would make both tests here trivially
   true regardless of whether the harness's network/storage wiring works. Test 1 instead asserts on
   the primary's full [(entries, commit_number)] pair after a real settle (so commitment, which
   needs Prepare_ok acks to actually arrive, is exercised); test 2 asserts on a BACKUP's own log
   length (which only grows when that backup's own copy of a given Prepare is actually delivered),
   under a nonzero drop rate, which is exactly what heavy drops directly threaten. *)

open Riptide
open Riptide_vsr

let v s = Value.Scalar (Value.String s)

(* Five distinct proposals (canonical-encoding dedup, per [Replica.propose]'s own doc comment,
   would otherwise silently drop a repeated value) on the pinned primary, [replicas.(0)], then one
   [settle] to let Prepare/Prepare_ok round trips actually happen -- so the returned pair reflects
   real quorum-committed state, not just what [propose] appended locally. *)
let primary_trace_of seed =
  let trace = ref ([], 0) in
  Riptide_dst.Cluster.run ~seed ~replica_count:3 (fun ~replicas ~settle ->
      for i = 0 to 4 do
        Replica.propose replicas.(0) (v (Printf.sprintf "payload-%d" i))
      done;
      settle ();
      trace := (Replica.entries replicas.(0), Replica.commit_number replicas.(0)));
  !trace

let test_same_seed_reproduces_byte_identical_trace () =
  let t1 = primary_trace_of 42 in
  let t2 = primary_trace_of 42 in
  (* Meaningful, not vacuous: assert directly that real replication/commitment happened at all
     (all 5 entries present AND fully committed under the default, fault-free network), then that
     re-running the identical seed reproduces that exact state byte-for-byte. A harness that
     silently failed to wire replicas together (e.g. every [send] a no-op) would still pass a bare
     equality check trivially -- it would not pass this one. *)
  let entries, commit_number = t1 in
  Alcotest.(check int) "primary log has all 5 proposals" 5 (List.length entries);
  Alcotest.(check int) "primary has committed all 5 proposals" 5 commit_number;
  Alcotest.(check bool) "same seed, byte-identical (entries, commit_number) trace" true (t1 = t2)

(* Proves the seed is actually load-bearing, not silently ignored: under a 50% drop rate, a
   backup's own log length after a fixed sequence of 10 proposals should not be the same for every
   seed -- some seeds' draws will drop enough of that backup's own Prepares to leave it behind,
   others won't. *)
let backup_log_length_of seed =
  let result = ref 0 in
  Riptide_dst.Cluster.run ~seed ~replica_count:3
    ~net_fault_config:
      Riptide_sim.Network.
        {
          drop_probability = 0.5;
          duplicate_probability = 0.0;
          corrupt_probability = 0.0;
          min_delay = 0.0;
          max_delay = 0.0;
        }
    (fun ~replicas ~settle ->
      for i = 0 to 9 do
        Replica.propose replicas.(0) (v (Printf.sprintf "payload-%d" i))
      done;
      settle ();
      result := List.length (Replica.entries replicas.(1)));
  !result

let test_different_seeds_can_diverge () =
  let seeds = [ 1; 2; 3; 4; 5; 6; 7; 8; 9; 10 ] in
  let results = List.map backup_log_length_of seeds in
  (* Sanity: every result must be a real, in-range log length -- catches a harness that raised or
     silently produced nonsense instead of a genuinely-run scenario. *)
  List.iter (fun r -> Alcotest.(check bool) "backup log length in [0, 10]" true (r >= 0 && r <= 10)) results;
  Alcotest.(check bool)
    "seeds are load-bearing: not every seed gives the identical backup log length under 50% drop"
    true
    (List.exists (fun r -> r <> List.hd results) results)

let tests =
  [
    ("same seed reproduces byte-identical trace", `Quick, test_same_seed_reproduces_byte_identical_trace);
    ("different seeds can diverge", `Quick, test_different_seeds_can_diverge);
  ]
