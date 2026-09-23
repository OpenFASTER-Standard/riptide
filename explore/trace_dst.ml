(* explore/trace_dst.ml -- single-seed verbose trace of the same scenario explore_dst.ml sweeps. *)

open Riptide
open Riptide_vsr

let v s = Value.Scalar (Value.String s)

let show_entries r =
  Replica.entries r
  |> List.map (fun x ->
         match x with Value.Scalar (Value.String s) -> s | _ -> "?")
  |> String.concat ","

let dump replicas phase =
  Printf.printf "  -- %s\n" phase;
  Array.iteri
    (fun i r ->
      Printf.printf "     r%d view=%d lnv=%d status=%s op=%d commit=%d log=[%s]\n" (i + 1)
        (Replica.view_number r) (Replica.last_normal_view r)
        (match Replica.status r with Replica.Normal -> "N" | Replica.View_change -> "VC")
        (Replica.op_number r) (Replica.commit_number r) (show_entries r))
    replicas

let () =
  let a n d = if Array.length Sys.argv > n then float_of_string Sys.argv.(n) else d in
  let ai n d = if Array.length Sys.argv > n then int_of_string Sys.argv.(n) else d in
  let seed = ai 1 320 in
  let replica_count = ai 2 5 in
  let rounds = ai 3 10 in
  let ops_per_round = ai 4 4 in
  let net =
    Riptide_sim.Network.
      {
        drop_probability = a 5 0.1;
        duplicate_probability = a 6 0.5;
        corrupt_probability = a 7 0.3;
        min_delay = 0.0;
        max_delay = 0.01;
      }
  in
  let storage =
    {
      Riptide_storage.Fault_injecting_storage.corrupt_probability = a 8 0.0;
      drop_probability = a 9 0.0;
      superblock_loss_probability = a 10 0.0;
    }
  in
  let timeout_prob = a 10 0.5 in
  let last_commit = Array.make replica_count 0 in
  let check replicas phase =
    Array.iteri
      (fun i r ->
        let cn = Replica.commit_number r in
        if cn < last_commit.(i) then
          Printf.printf "  *** [%s] replica %d commit_number REGRESSED %d -> %d\n" phase (i + 1)
            last_commit.(i) cn;
        last_commit.(i) <- max last_commit.(i) cn)
      replicas
  in
  (try
     Riptide_dst.Cluster.run ~seed ~replica_count ~net_fault_config:net
       ~storage_fault_config:storage (fun ~replicas ~settle ~restart:_ ->
         let p = Riptide_sim.Prng.create (((seed * 7919) + 13) land 0x3FFFFFFF) in
         let next_val = ref 0 in
         let find_primary () =
           let primary = ref None in
           Array.iteri
             (fun i r ->
               if Replica.is_primary r && Replica.status r = Replica.Normal then primary := Some i)
             replicas;
           !primary
         in
         let storm () =
           Array.iter (fun r -> Replica.check_timeout r) replicas;
           settle ()
         in
         for round = 0 to rounds - 1 do
           Printf.printf "ROUND %d\n" round;
           if find_primary () = None then begin
             Printf.printf "  (no primary -> storm)\n";
             storm ();
             dump replicas "after no-primary storm";
             check replicas "storm"
           end;
           (match find_primary () with
           | Some i ->
               for _ = 1 to ops_per_round do
                 Replica.propose replicas.(i) (v (Printf.sprintf "op-%d" !next_val));
                 incr next_val
               done;
               Printf.printf "  (proposed on r%d)\n" (i + 1)
           | None -> Printf.printf "  (still no primary)\n");
           settle ();
           dump replicas "after-propose";
           check replicas "after-propose";
           if Riptide_sim.Prng.bool p timeout_prob then begin
             Printf.printf "  (timeout storm)\n";
             storm ();
             dump replicas "after-timeout";
             check replicas "after-timeout"
           end
         done)
   with e -> Printf.printf "EXN %s\n" (Printexc.to_string e));
  Printf.printf "%!"
