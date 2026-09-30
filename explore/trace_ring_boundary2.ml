(* explore/trace_ring_boundary2.ml -- subtask 3.8's investigation tool, wire-level variant.
   Hand-rolled cluster (mirrors file_cluster.ml's wiring) over real File_storage, with every
   send logged (decoded to message shape) so the exact wire traffic during a storm that fails to
   converge can be inspected directly -- see trace_ring_boundary.ml's own header for the finding
   this tool was built to help pin down, and lib/dst/cluster.ml's doc history for the full account.

   USAGE: dune exec explore/trace_ring_boundary2.exe -- <seed> <ops_past_ring> <ring_capacity>
   <storms>, run in a loop under induced CPU load. *)

open Riptide
open Riptide_vsr

let v s = Value.Scalar (Value.String s)

let msg_summary bytes =
  match Message.decode bytes with
  | exception _ -> "MALFORMED"
  | Message.Prepare { view; n; k; _ } -> Printf.sprintf "Prepare(view=%d,n=%d,k=%d)" view n k
  | Message.Prepare_ok { view; n; i } -> Printf.sprintf "PrepareOk(view=%d,n=%d,i=%d)" view n i
  | Message.Start_view_change { v; i } -> Printf.sprintf "StartViewChange(v=%d,i=%d)" v i
  | Message.Do_view_change { v; n; k; last_normal_view; i; _ } ->
    Printf.sprintf "DoViewChange(v=%d,n=%d,k=%d,lnv=%d,i=%d)" v n k last_normal_view i
  | Message.Start_view { v; n; k; _ } -> Printf.sprintf "StartView(v=%d,n=%d,k=%d)" v n k

let dump replicas phase =
  Printf.printf "  -- %s\n" phase;
  Array.iteri
    (fun i r ->
      Printf.printf
        "     r%d view=%d lnv=%d status=%s op=%d commit=%d primary=%b\n" (i + 1)
        (Replica.view_number r) (Replica.last_normal_view r)
        (match Replica.status r with Replica.Normal -> "N" | Replica.View_change -> "VC")
        (Replica.op_number r) (Replica.commit_number r) (Replica.is_primary r))
    replicas;
  Printf.printf "%!"

exception Cluster_done

let rec rm_rf p =
  if Sys.is_directory p then begin
    Array.iter (fun f -> rm_rf (Filename.concat p f)) (Sys.readdir p);
    Unix.rmdir p
  end
  else Sys.remove p

let () =
  let ai n d = if Array.length Sys.argv > n then int_of_string Sys.argv.(n) else d in
  let seed = ai 1 1 in
  let ops_past_ring = ai 2 10 in
  let replica_count = 3 in
  let ring_capacity = ai 3 64 in
  let storms = ai 4 3 in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let dir =
    let d = Filename.temp_file "riptide_trace2" "" in
    Sys.remove d;
    Unix.mkdir d 0o700;
    d
  in
  let net = Riptide_sim.Network.create ~seed () in
  for id = 1 to replica_count do
    Riptide_sim.Network.register net (string_of_int id)
  done;
  let handles = Array.init replica_count (fun i -> Riptide_sim.Sim_transport.create net (i + 1)) in
  let send_for i ~to_ bytes =
    Printf.printf "     SEND r%d -> r%d: %s\n%!" (i + 1) to_ (msg_summary bytes);
    Riptide_sim.Sim_transport.send handles.(i) ~to_ bytes
  in
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  let storages =
    Array.init replica_count (fun i ->
        let path = Filename.concat dir (string_of_int (i + 1)) in
        Riptide_vsr.Replica.storage_of_module
          (module Riptide_storage.File_storage)
          (Riptide_storage.File_storage.create ~sw ~fs ~ring_capacity path))
  in
  let replicas =
    Array.init replica_count (fun i ->
        let my_id = i + 1 in
        let r =
          Riptide_vsr.Replica.create ~storage:storages.(i) ~my_id ~replica_count ~svc_limit:3
            ~send:(send_for i) ()
        in
        Riptide_vsr.Replica.for_test_set_view_number r 1;
        r)
  in
  let inflight = ref 0 in
  (try
     Eio.Switch.run (fun sw2 ->
         Array.iteri
           (fun i _ ->
             Eio.Fiber.fork ~sw:sw2 (fun () ->
                 let rec loop () =
                   let msg, sender = Riptide_sim.Sim_transport.receive handles.(i) in
                   (match Riptide_vsr.Replica.handle_message replicas.(i) ~sender msg with
                   | () -> ()
                   (* Catches exactly [Riptide_vsr.Replica.Sender_mismatch] (audit-remediation
                      Task 3), not the blanket [Invalid_argument] -- see replica.mli /
                      lib/dst/cluster.ml's own dispatch loop for why: [Invalid_argument] is also
                      what [durable_append] re-raises for an unclassified backend refusal, which
                      must propagate here rather than be swallowed.

                      Also catches [Riptide_vsr.Replica.Committed_prefix_mismatch]
                      (audit-remediation Task 33), by name, for the identical reason -- see
                      replica.mli / lib/dst/cluster.ml's own dispatch loop for the full rationale. *)
                   | exception Riptide_vsr.Replica.Sender_mismatch _ -> ()
                   | exception Riptide_vsr.Replica.Committed_prefix_mismatch _ -> ());
                   decr inflight;
                   loop ()
                 in
                 loop ()))
           replicas;
         let settle () =
           let deadline = ref None in
           let rounds_left = ref 500 in
           let rec go () =
             let delivered = ref false in
             while Riptide_sim.Network.pump_one net do
               delivered := true;
               incr inflight
             done;
             if !delivered then begin
               deadline := None;
               decr rounds_left;
               if !rounds_left <= 0 then failwith "Did_not_settle (delivery_rounds)"
               else (Eio.Fiber.yield (); go ())
             end
             else if !inflight > 0 then begin
               (match !deadline with
               | None -> deadline := Some (Eio.Time.now clock +. 5.0)
               | Some d -> if Eio.Time.now clock > d then failwith "Did_not_settle (deadline)");
               Eio.Time.sleep clock 0.0001;
               go ()
             end
             else ()
           in
           go ()
         in
         let next = ref 0 in
         for _ = 1 to ops_past_ring do
           Replica.propose replicas.(0) (v (Printf.sprintf "op-%d" !next));
           incr next
         done;
         settle ();
         dump replicas "after initial propose+settle";
         for storm_n = 1 to storms do
           Printf.printf "  == STORM %d ==\n%!" storm_n;
           Array.iter (fun r -> Replica.check_timeout r) replicas;
           settle ();
           dump replicas (Printf.sprintf "after storm %d" storm_n)
         done;
         raise Cluster_done)
   with Cluster_done -> ());
  let ok = Array.for_all (fun r -> Replica.status r = Replica.Normal) replicas in
  Printf.printf "RESULT returned_to_normal=%b\n%!" ok;
  (try rm_rf dir with _ -> ())
