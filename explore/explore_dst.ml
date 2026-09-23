(* explore/explore_dst.ml -- Task 11 EXPLORATION harness (not the permanent test).

   A standalone executable, deliberately NOT an Alcotest test: test/test_riptide.ml arms a 5s
   repeating wall-clock alarm over the whole suite, which a several-hundred-seed sweep would trip
   long before it found anything. Run it directly:

     dune exec explore/explore_dst.exe -- <seed_from> <seed_count> <replicas> <rounds> <ops/round>
       <net_drop> <net_dup> <net_corrupt> <storage_corrupt> <storage_drop> <timeout_prob>
*)

open Riptide
open Riptide_vsr

let v s = Value.Scalar (Value.String s)

type report = {
  violations : string list;
  outcome : string;
  max_view : int;
  committed_slots : int;
  no_primary_rounds : int;
  max_op : int;
  unreadable_slots : int;
}

let run_scenario ~seed ~replica_count ~rounds ~ops_per_round ~timeout_prob ~net ~storage =
  let violations = ref [] in
  let note fmt = Printf.ksprintf (fun s -> violations := s :: !violations) fmt in
  (* The actual cross-replica safety property: op_number -> the canonical encoding some replica
     has reported committed at that slot. Two replicas reporting different values at the same
     committed slot is the violation this whole plan exists to prevent. *)
  let committed : (int, string * int) Hashtbl.t = Hashtbl.create 64 in
  let last_commit = Array.make replica_count 0 in
  (* TASK 11 FOLLOW-UP instrumentation. The permanent test used to excuse a commit_number
     regression at [is_primary && status = Normal && last_normal_view = view_number]. That
     condition is vacuous: [last_normal_view = view_number] is implied by [status = Normal] (every
     path to Normal sets both together), so it reduces to "any primary in its ordinary steady
     state". What actually distinguishes "just completed SendSV" from steady state is observable
     only as a TRANSITION, so record each replica's view at the previous check and report whether
     the view had just advanced. *)
  let prev_view = Array.make replica_count (-1) in
  let check replicas phase =
    Array.iteri
      (fun i r ->
        let cn = Replica.commit_number r in
        if cn < last_commit.(i) then
          note
            "[%s] replica %d commit_number REGRESSED %d -> %d (is_primary=%b status=%s view=%d \
             lnv=%d prev_view=%d view_advanced=%b)"
            phase (i + 1) last_commit.(i) cn (Replica.is_primary r)
            (match Replica.status r with Replica.Normal -> "N" | _ -> "VC")
            (Replica.view_number r) (Replica.last_normal_view r) prev_view.(i)
            (Replica.view_number r > prev_view.(i));
        prev_view.(i) <- Replica.view_number r;
        last_commit.(i) <- max last_commit.(i) cn;
        let entries = Array.of_list (Replica.entries r) in
        if cn > Array.length entries then
          note "[%s] replica %d commit_number %d EXCEEDS its own log length %d" phase (i + 1) cn
            (Array.length entries);
        let bound = min cn (Array.length entries) in
        for n = 1 to bound do
          let enc = Value.canonical_encode entries.(n - 1) in
          match Hashtbl.find_opt committed n with
          | None -> Hashtbl.add committed n (enc, i + 1)
          | Some (prev, who) when prev <> enc ->
              note "[%s] DIVERGENCE at op %d: replica %d committed %S, replica %d committed %S"
                phase (i + 1) (i + 1) enc who prev
          | Some _ -> ()
        done)
      replicas;
    (* DURABILITY, the property this whole plan exists to protect: every op some replica has
       reported committed must still be held, with that same value, by at least one replica --
       in memory, and (separately) readable off at least one replica's own durable storage. *)
    Hashtbl.iter
      (fun n (enc, who) ->
        let in_memory = ref false and on_disk = ref false in
        Array.iter
          (fun r ->
            let e = Array.of_list (Replica.entries r) in
            if Array.length e >= n && Value.canonical_encode e.(n - 1) = enc then in_memory := true;
            match Replica.for_test_wal_read r ~op_number:n with
            | Some v when Value.canonical_encode v = enc -> on_disk := true
            | _ -> ())
          replicas;
        if not !in_memory then
          note "[%s] COMMITTED ENTRY LOST IN MEMORY: op %d (%S, first reported by r%d) is held by no replica"
            phase n enc who;
        if not !on_disk then
          note "[%s] COMMITTED ENTRY LOST ON DISK: op %d (%S, first reported by r%d) is durably readable on no replica"
            phase n enc who)
      committed
  in
  let outcome = ref "ok" in
  let max_view = ref 0 in
  let no_primary_rounds = ref 0 in
  let max_op = ref 0 in
  let unreadable_slots = ref 0 in
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
         (* A "timeout storm": every replica's own timer fires. Firing on only a random subset
            reproduces this module's own documented liveness gap (point 4 of
            spec/tla/README.md's "Known simplifications") and wedges the cluster in View_change
            for the rest of the run, which makes a SAFETY hunt vacuous -- nothing commits after
            the first wedge. Firing on all of them is what actually completes a view change and
            keeps the run producing committed state to compare across replicas. *)
         let storm () =
           Array.iter (fun r -> Replica.check_timeout r) replicas;
           settle ()
         in
         for _round = 0 to rounds - 1 do
           if find_primary () = None then storm ();
           let primary = ref (find_primary ()) in
           (match !primary with
           | Some i ->
               for _ = 1 to ops_per_round do
                 Replica.propose replicas.(i) (v (Printf.sprintf "op-%d" !next_val));
                 incr next_val
               done
           | None -> incr no_primary_rounds);
           Array.iter
             (fun r ->
               max_view := max !max_view (Replica.view_number r);
               max_op := max !max_op (Replica.op_number r))
             replicas;
           settle ();
           check replicas "after-propose";
           if Riptide_sim.Prng.bool p timeout_prob then storm ();
           check replicas "after-timeout";
           (* How much storage fault injection actually landed and is still live: a slot this
              replica holds in memory but cannot read back off its own durable storage. *)
           Array.iter
             (fun r ->
               for n = 1 to Replica.op_number r do
                 if Replica.for_test_wal_read r ~op_number:n = None then incr unreadable_slots
               done)
             replicas
         done)
   with
  | Riptide_dst.Cluster.Did_not_settle -> outcome := "did_not_settle"
  | Invalid_argument m -> outcome := Printf.sprintf "Invalid_argument %S" m
  | e -> outcome := Printf.sprintf "exn %s" (Printexc.to_string e));
  {
    violations = List.rev !violations;
    outcome = !outcome;
    max_view = !max_view;
    committed_slots = Hashtbl.length committed;
    no_primary_rounds = !no_primary_rounds;
    max_op = !max_op;
    unreadable_slots = !unreadable_slots;
  }

let () =
  let a n d = if Array.length Sys.argv > n then float_of_string Sys.argv.(n) else d in
  let ai n d = if Array.length Sys.argv > n then int_of_string Sys.argv.(n) else d in
  let seed_from = ai 1 1 in
  let seed_count = ai 2 50 in
  let replica_count = ai 3 5 in
  let rounds = ai 4 4 in
  let ops_per_round = ai 5 5 in
  let net =
    Riptide_sim.Network.
      {
        drop_probability = a 6 0.1;
        duplicate_probability = a 7 0.1;
        corrupt_probability = a 8 0.05;
        min_delay = 0.0;
        max_delay = 0.01;
      }
  in
  let storage =
    {
      Riptide_storage.Fault_injecting_storage.corrupt_probability = a 9 0.05;
      drop_probability = a 10 0.0;
      superblock_loss_probability = a 11 0.0;
    }
  in
  let timeout_prob = a 11 0.2 in
  let outcomes = Hashtbl.create 8 in
  let bad = ref 0 in
  let tot_view = ref 0 and tot_slots = ref 0 and tot_noprim = ref 0 and tot_op = ref 0 in
  let tot_unread = ref 0 in
  for seed = seed_from to seed_from + seed_count - 1 do
    let r =
      run_scenario ~seed ~replica_count ~rounds ~ops_per_round ~timeout_prob ~net ~storage
    in
    tot_view := !tot_view + r.max_view;
    tot_slots := !tot_slots + r.committed_slots;
    tot_noprim := !tot_noprim + r.no_primary_rounds;
    tot_op := !tot_op + r.max_op;
    tot_unread := !tot_unread + r.unreadable_slots;
    let prev = try Hashtbl.find outcomes r.outcome with Not_found -> 0 in
    Hashtbl.replace outcomes r.outcome (prev + 1);
    if r.violations <> [] then begin
      incr bad;
      Printf.printf "seed %d: %d violation(s), outcome=%s\n" seed (List.length r.violations)
        r.outcome;
      List.iteri (fun i s -> if i < 4 then Printf.printf "    %s\n" s) r.violations
    end
  done;
  Printf.printf "--- %d seeds from %d, replicas=%d rounds=%d ops/round=%d\n" seed_count seed_from
    replica_count rounds ops_per_round;
  Hashtbl.iter (fun k n -> Printf.printf "    outcome %-40s %d\n" k n) outcomes;
  Printf.printf "    seeds with violations: %d\n" !bad;
  let f = float_of_int seed_count in
  Printf.printf
    "    avg max_view=%.2f  avg committed_slots=%.2f  avg max_op=%.2f  avg no_primary_rounds=%.2f\n%!"
    (float_of_int !tot_view /. f)
    (float_of_int !tot_slots /. f)
    (float_of_int !tot_op /. f)
    (float_of_int !tot_noprim /. f);
  Printf.printf "    avg live-unreadable-slot observations=%.2f\n%!" (float_of_int !tot_unread /. f)
