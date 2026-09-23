(* explore/file_cluster.ml -- Task 11 exploration, lead 1: the same adversarial scenario, but with
   every replica driven over a REAL Riptide_storage.File_storage (O_DIRECT ring WAL + 3-copy
   superblock) instead of Memory_storage, under Eio_main.run instead of Eio_mock.Backend.run.

   Nothing in this repo has ever run a Replica over File_storage inside a cluster. *)

open Riptide
open Riptide_vsr

let v s = Value.Scalar (Value.String s)

exception Cluster_test_done

let run_scenario ~env ~seed ~replica_count ~ring_capacity ~rounds ~ops_per_round ~timeout_prob ~net
    ~storage_faults =
  let violations = ref [] in
  let note fmt = Printf.ksprintf (fun s -> violations := s :: !violations) fmt in
  let committed : (int, string * int) Hashtbl.t = Hashtbl.create 64 in
  let last_commit = Array.make replica_count 0 in
  let outcome = ref "ok" in
  let max_op = ref 0 and max_view = ref 0 and no_primary = ref 0 in
  let check replicas phase =
    Array.iteri
      (fun i r ->
        let cn = Replica.commit_number r in
        if cn < last_commit.(i) then
          note "[%s] replica %d commit_number REGRESSED %d -> %d" phase (i + 1) last_commit.(i) cn;
        last_commit.(i) <- max last_commit.(i) cn;
        let entries = Array.of_list (Replica.entries r) in
        if cn > Array.length entries then
          note "[%s] replica %d commit_number %d EXCEEDS log length %d" phase (i + 1) cn
            (Array.length entries);
        let bound = min cn (Array.length entries) in
        for n = 1 to bound do
          let enc = Value.canonical_encode entries.(n - 1) in
          match Hashtbl.find_opt committed n with
          | None -> Hashtbl.add committed n (enc, i + 1)
          | Some (prev, who) when prev <> enc ->
              note "[%s] DIVERGENCE at op %d: replica %d has %S, replica %d had %S" phase (i + 1)
                (i + 1) enc who prev
          | Some _ -> ()
        done)
      replicas
  in
  let inflight = ref 0 in
  let root = Riptide_sim.Prng.create seed in
  let net_seed = Riptide_sim.Prng.int root 0x3FFFFFFF in
  let storage_seeds = Array.init replica_count (fun _ -> Riptide_sim.Prng.int root 0x3FFFFFFF) in
  let dir = Filename.concat (Filename.get_temp_dir_name ()) (Printf.sprintf "riptide-fc-%d-%d" seed (Unix.getpid ())) in
  Unix.mkdir dir 0o700;
  let fs = Eio.Stdenv.fs env in
  (try
     Eio.Switch.run @@ fun sw ->
     let n = Riptide_sim.Network.create ~faults:net (Riptide_sim.Prng.create net_seed) () in
     for id = 1 to replica_count do
       Riptide_sim.Network.register n (string_of_int id)
     done;
     let handles = Array.init replica_count (fun i -> Riptide_sim.Sim_transport.create n (i + 1)) in
     let replication_quorum = ((replica_count - 1) / 2) + 1 in
     let storages =
       Array.init replica_count (fun i ->
           let path = Filename.concat dir (string_of_int (i + 1)) in
           let fstore = Riptide_storage.File_storage.create ~sw ~fs:(Eio.Path.( / ) fs "/") ~ring_capacity path in
           Riptide_storage.Fault_injecting_storage.create
             ~prng:(Riptide_sim.Prng.create storage_seeds.(i))
             ~fault_config:storage_faults ~replication_quorum
             ~underlying:(module Riptide_storage.File_storage)
             fstore)
     in
     let replicas =
       Array.init replica_count (fun i ->
           let r =
             Replica.create
               ~storage:
                 (Replica.storage_of_module (module Riptide_storage.Fault_injecting_storage) storages.(i))
               ~my_id:(i + 1) ~replica_count ~svc_limit:3
               ~send:(fun ~to_ bytes -> Riptide_sim.Sim_transport.send handles.(i) ~to_ bytes)
           in
           Replica.for_test_set_view_number r 1;
           r)
     in
     (* I/O-AWARE SETTLE. Cluster.run's own pump-then-yield-twice loop is only a valid quiescence
        detector while handle_message is synchronous (Memory_storage under Eio_mock). Against a
        real File_storage every handler SUSPENDS on io_uring, so [Fiber.yield] returns long before
        the handler has finished, [pump_one] then reports nothing pending, and settle returns with
        the cluster still mid-flight. [inflight] counts messages delivered but not yet fully
        handled; a real (tiny) sleep is what actually lets io_uring completions land. *)
     let old_settle = Sys.getenv_opt "OLD_SETTLE" <> None in
     let settle () =
       if old_settle then begin
         (* Cluster.run's CURRENT settle, verbatim. *)
         let rec loop rounds_left =
           if rounds_left <= 0 then failwith "did not settle"
           else begin
             let delivered = ref false in
             while Riptide_sim.Network.pump_one n do delivered := true done;
             Eio.Fiber.yield ();
             Eio.Fiber.yield ();
             if !delivered then loop (rounds_left - 1)
           end
         in
         loop 20
       end
       else
       let rec loop fuel =
         if fuel <= 0 then failwith "did not settle"
         else begin
           let delivered = ref false in
           while Riptide_sim.Network.pump_one n do
             delivered := true;
             incr inflight
           done;
           Eio.Fiber.yield ();
           if !inflight > 0 then begin
             Eio.Time.sleep (Eio.Stdenv.clock env) 0.0002;
             loop (fuel - 1)
           end
           else if !delivered then loop (fuel - 1)
         end
       in
       loop 5000
     in
     Array.iteri
       (fun i replica ->
         Eio.Fiber.fork ~sw (fun () ->
             let rec dispatch () =
               let msg = Riptide_sim.Sim_transport.receive handles.(i) in
               Replica.handle_message replica msg;
               decr inflight;
               dispatch ()
             in
             dispatch ()))
       replicas;
     let p = Riptide_sim.Prng.create (((seed * 7919) + 13) land 0x3FFFFFFF) in
     let next_val = ref 0 in
     let find_primary () =
       let primary = ref None in
       Array.iteri
         (fun i r -> if Replica.is_primary r && Replica.status r = Replica.Normal then primary := Some i)
         replicas;
       !primary
     in
     let storm () =
       Array.iter (fun r -> Replica.check_timeout r) replicas;
       settle ()
     in
     for _round = 0 to rounds - 1 do
       if find_primary () = None then storm ();
       (match find_primary () with
       | Some i ->
           for _ = 1 to ops_per_round do
             Replica.propose replicas.(i) (v (Printf.sprintf "op-%d" !next_val));
             incr next_val
           done
       | None -> incr no_primary);
       settle ();
       if Sys.getenv_opt "TRACE" <> None then
         Array.iteri (fun i r -> Printf.printf "   r%d view=%d st=%s op=%d commit=%d loglen=%d\n" (i+1) (Replica.view_number r) (match Replica.status r with Replica.Normal -> "N" | _ -> "VC") (Replica.op_number r) (Replica.commit_number r) (List.length (Replica.entries r))) replicas;
       check replicas "after-propose";
       Array.iter
         (fun r ->
           max_op := max !max_op (Replica.op_number r);
           max_view := max !max_view (Replica.view_number r))
         replicas;
       if Riptide_sim.Prng.bool p timeout_prob then storm ();
       check replicas "after-timeout"
     done;
     Eio.Switch.fail sw Cluster_test_done
   with
  | Cluster_test_done -> ()
  | e -> outcome := Printexc.to_string e);
  (!violations, !outcome, !max_op, !max_view, !no_primary, Hashtbl.length committed)

let () =
  let a k d = if Array.length Sys.argv > k then float_of_string Sys.argv.(k) else d in
  let ai k d = if Array.length Sys.argv > k then int_of_string Sys.argv.(k) else d in
  let seed_from = ai 1 1 and seed_count = ai 2 10 in
  let replica_count = ai 3 3 and ring_capacity = ai 4 8 in
  let rounds = ai 5 5 and ops_per_round = ai 6 4 in
  let net =
    Riptide_sim.Network.
      {
        drop_probability = a 7 0.0;
        duplicate_probability = a 8 0.0;
        corrupt_probability = 0.0;
        min_delay = 0.0;
        max_delay = a 9 0.0;
      }
  in
  let storage_faults =
    { Riptide_storage.Fault_injecting_storage.corrupt_probability = a 10 0.0; drop_probability = 0.0 }
  in
  let timeout_prob = a 11 0.0 in
  Eio_main.run @@ fun env ->
  for seed = seed_from to seed_from + seed_count - 1 do
    let violations, outcome, max_op, max_view, no_primary, slots =
      run_scenario ~env ~seed ~replica_count ~ring_capacity ~rounds ~ops_per_round ~timeout_prob
        ~net ~storage_faults
    in
    Printf.printf "seed %d: outcome=%s max_op=%d max_view=%d no_primary=%d committed_slots=%d violations=%d\n"
      seed outcome max_op max_view no_primary slots (List.length violations);
    List.iteri (fun i s -> if i < 5 then Printf.printf "    %s\n" s) (List.rev violations)
  done;
  Printf.printf "%!"
