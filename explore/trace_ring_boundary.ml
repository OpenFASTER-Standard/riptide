(* explore/trace_ring_boundary.ml -- subtask 3.8's investigation tool. Reproduces
   test_dst_scenarios.ml's test_ring_capacity_boundary's FIRST case (ring_capacity:64,
   ops_past_ring:10 -- should always converge) with rich per-storm tracing, to see exactly what
   state each replica is in when the assertion fails under CPU load.

   USAGE: dune exec explore/trace_ring_boundary.exe -- <seed> <ops_past_ring> <ring_capacity>
   <storms>. Run in a loop under induced CPU load (several busy-loop processes) to reproduce the
   real, non-deterministic failure this tool exists to characterize -- see lib/dst/cluster.ml's own
   doc history (search "FOLLOW-UP FINDING") for the full account this tool's output supports:
   test_ring_capacity_boundary's scenario is not deterministic at a fixed seed against real
   File_storage (real per-replica disk I/O completion timing, not the seeded PRNG, decides
   message-processing order), and its third forced storm occasionally (~2% under load) leaves two
   replicas stuck in View_change -- rescuable only by MORE storms, not by settle() waiting longer.
   [storms] > 3 demonstrates the rescue directly. *)

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
