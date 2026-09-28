(* explore/trace_ring_boundary.ml -- subtask 3.8's investigation tool. Reproduces
   test_dst_scenarios.ml's test_ring_capacity_boundary's FIRST case (ring_capacity:64,
   ops_past_ring:10 -- should always converge) with rich per-storm tracing, to see exactly what
   state each replica is in when the assertion fails under CPU load.

   USAGE: dune exec explore/trace_ring_boundary.exe -- <seed> <ops_past_ring> <ring_capacity>
   <storms>. Run in a loop under induced CPU load (several busy-loop processes) against
   lib/dst/cluster.ml's PRE-FIX state to reproduce the real failure this tool was built to
   characterize -- see cluster.ml's own doc history (search "THE REAL ROOT CAUSE") for the full,
   VERIFIED account. Against the current, fixed cluster.ml, [test_ring_capacity_boundary] no
   longer fails at a rate this tool's own sample sizes have the resolution to detect either way --
   this tool's own value now is as a reproduction of the FIXED bug for anyone re-verifying the fix,
   not as a live flake detector.

   CORRECTION: an earlier version of this comment claimed the real mechanism was genuine real-I/O
   timing non-determinism specific to the third of three forced storms, rescuable only by more
   independent storms. That was itself an overclaim, caught by independent review: the real defect
   was in Cluster.for_test_settle_loop itself (a stale-read TOCTOU race that could declare
   quiescence with a real message still undelivered), occurred at a roughly uniform rate across
   EVERY forced storm (not concentrated on the third -- storms 1/2's own occurrences were simply
   invisible, rescued by the next storm's own settle call before anyone looked), and is now fixed
   in cluster.ml directly, not by adding more storms. Only the interpretation in this header was
   wrong; what the tool itself does (drive real check_timeout storms over real File_storage and
   dump each replica's state) was always accurate. *)

open Riptide
open Riptide_vsr

let v s = Value.Scalar (Value.String s)

let dump replicas phase =
  Printf.printf "  -- %s\n" phase;
  Array.iteri
    (fun i r ->
      Printf.printf
        "     r%d view=%d lnv=%d status=%s op=%d commit=%d primary=%b entries=%d\n" (i + 1)
        (Replica.view_number r) (Replica.last_normal_view r)
        (match Replica.status r with Replica.Normal -> "N" | Replica.View_change -> "VC")
        (Replica.op_number r) (Replica.commit_number r) (Replica.is_primary r)
        (List.length (Replica.entries r)))
    replicas;
  Printf.printf "%!"

let () =
  let ai n d = if Array.length Sys.argv > n then int_of_string Sys.argv.(n) else d in
  let seed = ai 1 1 in
  let ops_past_ring = ai 2 10 in
  let ring_capacity = ai 3 64 in
  let storms = ai 4 3 in
  Eio_main.run @@ fun env ->
  let dir =
    let d = Filename.temp_file "riptide_trace_ring" "" in
    Sys.remove d;
    Unix.mkdir d 0o700;
    d
  in
  let returned_to_normal = ref false in
  (try
     Riptide_dst.Cluster.run_on_file_storage ~env ~dir ~seed ~replica_count:3 ~ring_capacity
       (fun ~replicas ~settle ~restart:_ ->
         let next = ref 0 in
         for _ = 1 to ops_past_ring do
           Replica.propose replicas.(0) (v (Printf.sprintf "op-%d" !next));
           incr next
         done;
         settle ();
         dump replicas "after initial propose+settle";
         for storm_n = 1 to storms do
           Array.iter (fun r -> Replica.check_timeout r) replicas;
           settle ();
           dump replicas (Printf.sprintf "after storm %d" storm_n)
         done;
         returned_to_normal :=
           Array.for_all (fun r -> Replica.status r = Replica.Normal) replicas)
   with e -> Printf.printf "EXN %s\n%!" (Printexc.to_string e));
  Printf.printf "RESULT returned_to_normal=%b\n%!" !returned_to_normal;
  (try
     let rec rm_rf p =
       if Sys.is_directory p then begin
         Array.iter (fun f -> rm_rf (Filename.concat p f)) (Sys.readdir p);
         Unix.rmdir p
       end
       else Sys.remove p
     in
     rm_rf dir
   with _ -> ())
