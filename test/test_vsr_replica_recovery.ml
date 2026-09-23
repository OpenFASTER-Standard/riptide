(* test/test_vsr_replica_recovery.ml

   Task 7: the OCaml transcription of spec/tla/VSR.tla's storage-fault-aware, multi-step,
   interruptible view-change completion (VSR.tla:403-471 [WinningDVC/NackCount/ProvenAbsent/
   EntrySources/CanFill/FillValue/ValidCompletion/CanComplete/CompletionPoint], :488-491
   [HasDvcQuorum], :499-516 [SendSV], :542-556 [ForfeitViewChange], :671-690 [CrashRestart]),
   wired to the real [Riptide_storage.Storage_intf.S].

   Scope split, deliberate: this file covers everything observable on a SINGLE replica driven by
   hand-built messages -- the two Review Focus guards, the tri-state storage mapping, the
   distinct-sender quorum projection, the nack-quorum truncation, the forfeit escape, and the
   durable/volatile split across a restart. Task 8 adds the end-to-end cluster test under real
   injected storage faults on top of the same API. *)

open Riptide
open Riptide_vsr

let v s = Value.Scalar (Value.String s)

let capturing_send () =
  let sent = ref [] in
  let send ~to_ bytes = sent := (to_, bytes) :: !sent in
  (send, fun () -> List.rev !sent)

let decoded_sent sent = List.map (fun (to_, bytes) -> (to_, Message.decode bytes)) (sent ())

(* One [Memory_storage.t] plus the [Replica.storage] view of it, so a test can reach BOTH the
   replica's own API and the raw backend (to inject corruption, or to re-open the same durable
   state as a "restarted" replica). *)
let fresh_storage () =
  let backend = Riptide_storage.Memory_storage.create () in
  (backend, Replica.storage_of_module (module Riptide_storage.Memory_storage) backend)

let dvc_msg ~v ~entries ~nacks ~last_normal_view ~n ~k ~i =
  Message.encode (Message.Do_view_change { v; entries; nacks; last_normal_view; n; k; i })

(* Entries as a full, gapless log -- the shape every DVC from a fault-free replica has. *)
let full_entries log = List.mapi (fun idx value -> (idx + 1, value)) log

(* ============================================================================================
   Review Focus item 1: [wal_truncate_after] below the already-committed op-number must be
   rejected by replica.ml, never silently accepted (VSR's own safety guarantee is that committed
   entries never disappear). *)

let test_truncate_wal_below_commit_number_is_rejected () =
  let send, _sent = capturing_send () in
  let _backend, storage = fresh_storage () in
  (* A backup at view 0 (Primary(0) = 3 at replica_count = 3), driven to op_number = 2 /
     commit_number = 1 by two real Prepares. *)
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 2; v = v "b"; k = 1 }));
  Alcotest.(check int) "op_number = 2 after two Prepares" 2 (Replica.op_number t);
  Alcotest.(check int) "commit_number = 1 after two Prepares" 1 (Replica.commit_number t);
  Alcotest.check_raises "truncate below commit_number is rejected"
    (Invalid_argument "recovery: refusing to truncate below commit_number") (fun () ->
      Replica.for_test_truncate_wal t ~op_number:0);
  (* ...and the rejection is a TOTAL no-op: the durable log is untouched, so the committed entry
     is still readable afterwards. *)
  Alcotest.(check int) "op_number unchanged by the rejected truncate" 2 (Replica.op_number t);
  Alcotest.(check bool) "committed entry still readable after the rejected truncate" true
    (Replica.for_test_wal_read t ~op_number:1 = Some (v "a"));
  (* The boundary itself (op_number = commit_number) is ACCEPTED -- the guard is "below", not
     "at or below": truncating away the uncommitted suffix is exactly what a legal completion
     does. *)
  Replica.for_test_truncate_wal t ~op_number:1;
  Alcotest.(check int) "truncate AT commit_number is accepted" 1 (Replica.op_number t);
  Alcotest.(check bool) "the uncommitted entry 2 is gone" true (Replica.for_test_wal_read t ~op_number:2 = None)

(* ============================================================================================
   Review Focus item 2: a nack referencing an op-number outside the range a sender can possibly
   prove absent is handled as a malformed input without crashing, matching this module's
   established "guard failure => total no-op" convention.

   The bound a nack must satisfy is [o > m.n]: by VSR.tla's own StorageWellFormed
   (VSR.tla:742-745) plus LogLengthMatchesOpNumber (:728-729), CanNack(r, o) holds precisely for
   the ops ABOVE the sender's own op-number -- an op at or below it is one the sender's own [n]
   claims it durably holds, so nacking it is a self-contradiction and exactly the shape a forged
   nack would take to manufacture a false ProvenAbsent quorum for a committed op. *)

let test_out_of_range_nack_is_a_total_no_op () =
  let send, sent = capturing_send () in
  let _backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.for_test_set_view t ~status:Replica.View_change ~view_number:5 ~last_normal_view:2;
  Alcotest.(check bool) "this replica is Primary(5) at replica_count = 3" true (Replica.is_primary t);
  (* Non-positive nacks: op-numbers are 1-indexed (VSR.tla's [ops == 1..MaxOp]). *)
  Replica.handle_message t (dvc_msg ~v:5 ~entries:[] ~nacks:[ 0 ] ~last_normal_view:2 ~n:0 ~k:0 ~i:1);
  Replica.handle_message t (dvc_msg ~v:5 ~entries:[] ~nacks:[ -7 ] ~last_normal_view:2 ~n:0 ~k:0 ~i:1);
  (* A nack AT or BELOW the sender's own op-number: contradicts its own [n]. *)
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:(full_entries [ v "a"; v "b" ]) ~nacks:[ 2 ] ~last_normal_view:2 ~n:2 ~k:1 ~i:1);
  Alcotest.(check (list int)) "every malformed-nack DVC was dropped wholesale" []
    (Replica.for_test_recv_dvc_senders t);
  Alcotest.(check bool) "nothing was sent in response" true (sent () = []);
  Alcotest.(check bool) "status unchanged" true (Replica.status t = Replica.View_change);
  Alcotest.(check int) "view_number unchanged" 5 (Replica.view_number t);
  (* A nack far outside any real log range is NOT malformed (it is above the sender's own [n],
     so the sender really can prove it absent) -- it must be accepted and then be provably inert,
     never crash or index anything. *)
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:[] ~nacks:[ 1_000_000_000 ] ~last_normal_view:2 ~n:0 ~k:0 ~i:1);
  Alcotest.(check (list int)) "the huge-but-valid nack DVC is accepted" [ 1 ]
    (Replica.for_test_recv_dvc_senders t);
  Alcotest.(check int) "op_number still 0 -- nothing was indexed or allocated by the huge nack" 0
    (Replica.op_number t)

(* ============================================================================================
   HasDvcQuorum (VSR.tla:488-491) counts DISTINCT SENDERS, not messages -- the exact safety
   defect Task 5's own review found and fixed in the TLA+ (spec/tla/README.md). This module makes
   one replica able to send two DIFFERENT DVCs in one episode for real (CrashRestart clears the
   volatile [sent_dvc] flag, so a restarted replica re-sends, with a smaller [entries] set). *)

let test_dvc_quorum_counts_distinct_senders_not_messages () =
  let send, sent = capturing_send () in
  let _backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.for_test_set_view t ~status:Replica.View_change ~view_number:5 ~last_normal_view:2;
  (* Sender 1 speaks twice, exactly as a mid-view-change restart makes it: first with both
     entries readable, then (after a slot faulted to corrupt) with only one. Two DISTINCT
     records, one replica. *)
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:(full_entries [ v "a"; v "b" ]) ~nacks:[] ~last_normal_view:2 ~n:2 ~k:0 ~i:1);
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:[ (1, v "a") ] ~nacks:[] ~last_normal_view:2 ~n:2 ~k:0 ~i:1);
  Alcotest.(check (list int)) "one sender, one entry" [ 1 ] (Replica.for_test_recv_dvc_senders t);
  Alcotest.(check bool) "no StartView: two messages from ONE replica are not an f+1 = 2 quorum" true
    (sent () = []);
  Alcotest.(check bool) "still in View_change" true (Replica.status t = Replica.View_change);
  (* A genuinely different sender completes the real quorum of 2 distinct senders. *)
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:(full_entries [ v "a"; v "b" ]) ~nacks:[] ~last_normal_view:2 ~n:2 ~k:0 ~i:3);
  Alcotest.(check bool) "completed once TWO DISTINCT senders reported" true (Replica.status t = Replica.Normal);
  Alcotest.(check bool) "and the completion carries both entries" true (Replica.entries t = [ v "a"; v "b" ])

(* ============================================================================================
   The multi-step sequence itself: a contested op blocks completion (the coordinator must WAIT,
   VSR.tla:403-409), and a nack quorum resolves it into a truncating completion
   (ValidCompletion/CompletionPoint, VSR.tla:459-471). *)

let test_contested_op_blocks_completion_then_a_nack_quorum_resolves_it () =
  let send, sent = capturing_send () in
  let _backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.for_test_set_view t ~status:Replica.View_change ~view_number:5 ~last_normal_view:2;
  (* Sender 1: the WINNER by (last_normal_view, n) -- n = 3 -- but it can only READ ops 1 and 2
     (op 3's slot is corrupt on its disk), so op 3 is neither fillable nor, yet, proven absent. *)
  Replica.handle_message t
    (dvc_msg ~v:5
       ~entries:[ (1, v "a"); (2, v "b") ]
       ~nacks:[] ~last_normal_view:2 ~n:3 ~k:0 ~i:1);
  (* Sender 3: n = 2, so it proves ops 3.. absent. One nack is below the f+1 = 2 quorum. *)
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:(full_entries [ v "a"; v "b" ]) ~nacks:[] ~last_normal_view:2 ~n:2 ~k:0 ~i:3);
  Alcotest.(check (list int)) "an f+1 = 2 DVC quorum has been reached" [ 1; 3 ]
    (Replica.for_test_recv_dvc_senders t);
  Alcotest.(check bool) "but NO StartView yet: op 3 is contested, so the sequence must wait" true (sent () = []);
  Alcotest.(check bool) "still View_change" true (Replica.status t = Replica.View_change);
  (* This replica's own DVC (VSR.tla:262-263's "including itself"): n = 2, the second nack for
     op 3, which reaches the f+1 = 2 nack quorum and makes op 3 PROVEN ABSENT. *)
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:(full_entries [ v "a"; v "b" ]) ~nacks:[] ~last_normal_view:2 ~n:2 ~k:0 ~i:2);
  Alcotest.(check bool) "the sequence completes once op 3 is proven absent" true (Replica.status t = Replica.Normal);
  Alcotest.(check int) "CompletionPoint is 2 -- the longest admissible log" 2 (Replica.op_number t);
  Alcotest.(check bool) "log reconstructed op-by-op from the canonical evidence" true
    (Replica.entries t = [ v "a"; v "b" ]);
  Alcotest.(check bool) "the truncation is durable too" true (Replica.for_test_wal_read t ~op_number:3 = None);
  Alcotest.(check bool) "StartView carries the completed log"
    (List.for_all (fun (_, m) -> m = Message.Start_view { v = 5; log = [ v "a"; v "b" ]; n = 2; k = 0 })
       (decoded_sent sent))
    true

(* ============================================================================================
   ForfeitViewChange (VSR.tla:542-556): enabled exactly when the coordinator holds a DVC quorum
   and STILL cannot complete. Effect: bump to view+1, reset the view-change bookkeeping,
   broadcast StartViewChange -- NOT fall back to Normal. *)

let test_forfeit_view_change_when_quorum_cannot_complete () =
  let send, sent = capturing_send () in
  let _backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.for_test_set_view t ~status:Replica.View_change ~view_number:5 ~last_normal_view:2;
  (* The same permanently-contested shape as above, minus the resolving third DVC. *)
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:[ (1, v "a"); (2, v "b") ] ~nacks:[] ~last_normal_view:2 ~n:3 ~k:0 ~i:1);
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:(full_entries [ v "a"; v "b" ]) ~nacks:[] ~last_normal_view:2 ~n:2 ~k:0 ~i:3);
  Alcotest.(check bool) "wedged: quorum held, nothing sent" true (sent () = []);
  Replica.check_timeout t;
  Alcotest.(check int) "forfeited to view + 1" 6 (Replica.view_number t);
  Alcotest.(check bool) "status stays View_change -- it does NOT fall back to Normal" true
    (Replica.status t = Replica.View_change);
  Alcotest.(check (list int)) "recv_dvc was reset for the fresh episode" [] (Replica.for_test_recv_dvc_senders t);
  Alcotest.(check (list int)) "recv_svc was reset for the fresh episode" [] (Replica.for_test_recv_svc_senders t);
  Alcotest.(check bool) "a StartViewChange for the new view was broadcast to the other two replicas" true
    (decoded_sent sent = [ (1, Message.Start_view_change { v = 6; i = 2 }); (3, Message.Start_view_change { v = 6; i = 2 }) ])

let test_no_forfeit_below_a_dvc_quorum () =
  let send, sent = capturing_send () in
  let _backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:2 ~replica_count:5 ~svc_limit:3 ~send ~storage in
  Replica.for_test_set_view t ~status:Replica.View_change ~view_number:7 ~last_normal_view:2;
  Alcotest.(check bool) "this replica is Primary(7) at replica_count = 5" true (Replica.is_primary t);
  (* One DVC only -- far below f+1 = 3. VSR.tla:528-531: forfeiting early would abandon an
     attempt that was still making progress, so the timer must NOT forfeit here. *)
  Replica.handle_message t
    (dvc_msg ~v:7 ~entries:[ (1, v "a") ] ~nacks:[] ~last_normal_view:2 ~n:3 ~k:0 ~i:1);
  Replica.check_timeout t;
  Alcotest.(check int) "view_number unchanged: no forfeit below a DVC quorum" 7 (Replica.view_number t);
  Alcotest.(check (list int)) "the single DVC's evidence was NOT thrown away" [ 1 ]
    (Replica.for_test_recv_dvc_senders t);
  Alcotest.(check bool) "nothing broadcast" true (sent () = [])

(* ============================================================================================
   The tri-state storage mapping (VSR.tla:100-170): a slot the replica can prove it never held
   ("absent") vs. one it holds but cannot read ("corrupt"). The whole soundness argument is that
   a corrupt slot is NEVER nacked and NEVER shipped as an entry. *)

let test_corrupt_slot_is_neither_shipped_nor_nacked () =
  let send, sent = capturing_send () in
  let backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 2; v = v "b"; k = 0 }));
  Alcotest.(check bool) "both entries are durable before the fault" true
    (Replica.for_test_wal_read t ~op_number:1 = Some (v "a")
    && Replica.for_test_wal_read t ~op_number:2 = Some (v "b"));
  (* The fault: slot 1 stops verifying. [wal_highest_op_number] is untouched, which is exactly
     what makes this "corrupt" and not "absent". *)
  Riptide_storage.Memory_storage.for_test_corrupt backend ~op_number:1;
  (* Drive a real SendDVC (VSR.tla:376-389) out of this replica. *)
  Replica.for_test_set_view t ~status:Replica.View_change ~view_number:2 ~last_normal_view:0;
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 2; i = 3 }));
  match List.rev (decoded_sent sent) with
  | (_, Message.Do_view_change { entries; nacks; n; _ }) :: _ ->
    Alcotest.(check int) "the DVC still claims the durable op_number" 2 n;
    Alcotest.(check (list int)) "only the READABLE slot is shipped as an entry" [ 2 ] (List.map fst entries);
    Alcotest.(check (list int)) "the corrupt slot is NOT nacked -- the load-bearing rule" [] nacks
  | _ -> Alcotest.fail "expected a DoViewChange to have been sent"

(* ============================================================================================
   CrashRestart (VSR.tla:671-690): the durable/volatile split, and status RECONSTRUCTED from
   [view > log_view] rather than stored. *)

let test_restart_preserves_durable_state_and_reconstructs_view_change_status () =
  let send, _sent = capturing_send () in
  let backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 2; v = v "b"; k = 1 }));
  (* Enter a view change for real, and accumulate the volatile bookkeeping a restart must lose. *)
  Replica.check_timeout t;
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 1; i = 3 }));
  Alcotest.(check (list int)) "recv_svc populated before the crash" [ 3 ] (Replica.for_test_recv_svc_senders t);
  Alcotest.(check bool) "mid-view-change before the crash" true (Replica.status t = Replica.View_change);
  let view_before = Replica.view_number t and lnv_before = Replica.last_normal_view t in
  (* The restart: a brand-new [Replica.t] over the SAME durable storage. *)
  let send2, _sent2 = capturing_send () in
  let storage2 = Replica.storage_of_module (module Riptide_storage.Memory_storage) backend in
  let t' = Replica.restart ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send:send2 ~storage:storage2 in
  Alcotest.(check int) "DURABLE: view_number" view_before (Replica.view_number t');
  Alcotest.(check int) "DURABLE: last_normal_view" lnv_before (Replica.last_normal_view t');
  Alcotest.(check int) "DURABLE: op_number" 2 (Replica.op_number t');
  Alcotest.(check int) "DURABLE: commit_number" 1 (Replica.commit_number t');
  Alcotest.(check bool) "DURABLE: log" true (Replica.entries t' = [ v "a"; v "b" ]);
  Alcotest.(check bool) "status RECONSTRUCTED from view > log_view, not stored" true
    (Replica.status t' = Replica.View_change);
  Alcotest.(check (list int)) "VOLATILE: recv_svc lost" [] (Replica.for_test_recv_svc_senders t');
  Alcotest.(check (list int)) "VOLATILE: recv_dvc lost" [] (Replica.for_test_recv_dvc_senders t')

let test_restart_outside_a_view_change_reconstructs_normal_status () =
  let send, _sent = capturing_send () in
  let backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Alcotest.(check bool) "Normal before the crash" true (Replica.status t = Replica.Normal);
  let send2, _ = capturing_send () in
  let storage2 = Replica.storage_of_module (module Riptide_storage.Memory_storage) backend in
  let t' = Replica.restart ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send:send2 ~storage:storage2 in
  Alcotest.(check bool) "view = log_view, so status reconstructs to Normal" true (Replica.status t' = Replica.Normal);
  Alcotest.(check int) "op_number survived" 1 (Replica.op_number t');
  Alcotest.(check bool) "log survived" true (Replica.entries t' = [ v "a" ])

(* A restart that DISCOVERS a corrupt slot: the durable op_number (superblock) is what makes the
   slot "corrupt" rather than "absent" after the restart, which is the single property the whole
   nack-soundness argument rests on (VSR.tla:112-147). *)
let test_restart_discovering_a_corrupt_slot_still_refuses_to_nack_it () =
  let send, _sent = capturing_send () in
  let backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 2; v = v "b"; k = 1 }));
  Riptide_storage.Memory_storage.for_test_corrupt backend ~op_number:2;
  let send2, sent2 = capturing_send () in
  let storage2 = Replica.storage_of_module (module Riptide_storage.Memory_storage) backend in
  let t' = Replica.restart ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send:send2 ~storage:storage2 in
  Alcotest.(check int) "op_number still 2 -- it comes from the superblock, not from readable slots" 2
    (Replica.op_number t');
  Replica.for_test_set_view t' ~status:Replica.View_change ~view_number:2 ~last_normal_view:0;
  Replica.handle_message t' (Message.encode (Message.Start_view_change { v = 2; i = 3 }));
  (match List.rev (decoded_sent sent2) with
  | (_, Message.Do_view_change { entries; nacks; n; _ }) :: _ ->
    Alcotest.(check int) "DVC's n is the durable op_number" 2 n;
    Alcotest.(check (list int)) "only the readable slot is shipped" [ 1 ] (List.map fst entries);
    Alcotest.(check (list int)) "the slot discovered corrupt at restart is NOT nacked" [] nacks
  | _ -> Alcotest.fail "expected a DoViewChange to have been sent")

(* VSR.tla:166-170, stated there as a requirement on the MODEL and equally one on this
   transcription: "this is deliberately not a readable *prefix*: a corrupt slot does not hide the
   slots after it, and a replica that can read op 2 but not op 1 is a real state this model must be
   able to express". A DVC's [entries] must therefore be able to have a NON-CONTIGUOUS domain. *)
let test_readable_entries_are_not_merely_a_prefix () =
  let send, _sent = capturing_send () in
  let backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 2; v = v "b"; k = 0 }));
  (* The FIRST slot faults, not the last -- so a prefix-only scan would ship nothing at all. *)
  Riptide_storage.Memory_storage.for_test_corrupt backend ~op_number:1;
  let send2, sent2 = capturing_send () in
  let storage2 = Replica.storage_of_module (module Riptide_storage.Memory_storage) backend in
  let t' = Replica.restart ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send:send2 ~storage:storage2 in
  Alcotest.(check int) "op_number is still the full durable 2" 2 (Replica.op_number t');
  Alcotest.(check bool) "the in-memory log IS only the readable prefix -- here, empty" true (Replica.entries t' = []);
  Replica.for_test_set_view t' ~status:Replica.View_change ~view_number:2 ~last_normal_view:0;
  Replica.handle_message t' (Message.encode (Message.Start_view_change { v = 2; i = 3 }));
  match List.rev (decoded_sent sent2) with
  | (_, Message.Do_view_change { entries; nacks; n; _ }) :: _ ->
    Alcotest.(check int) "n is the durable op_number, not the readable count" 2 n;
    Alcotest.(check (list int)) "op 2 is shipped even though op 1 below it is unreadable" [ 2 ]
      (List.map fst entries);
    Alcotest.(check bool) "and it is the right value" true (List.assoc 2 entries = v "b");
    Alcotest.(check (list int)) "still nothing nacked" [] nacks
  | _ -> Alcotest.fail "expected a DoViewChange to have been sent"

(* EntrySources/CanFill/FillValue (VSR.tla:440-444): an op the WINNER cannot read is filled from a
   peer at the SAME log_view -- this is how a corrupt slot on the would-be primary gets repaired
   instead of forcing a truncation. *)
let test_an_unreadable_winner_entry_is_filled_from_a_same_log_view_peer () =
  let send, sent = capturing_send () in
  let _backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.for_test_set_view t ~status:Replica.View_change ~view_number:5 ~last_normal_view:2;
  (* The winner by (last_normal_view, n) cannot read its own op 1. *)
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:[ (2, v "b") ] ~nacks:[] ~last_normal_view:2 ~n:2 ~k:1 ~i:1);
  (* A peer at the SAME log_view supplies it. *)
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:[ (1, v "a") ] ~nacks:[] ~last_normal_view:2 ~n:2 ~k:0 ~i:3);
  Alcotest.(check bool) "the view change completed without truncating" true (Replica.status t = Replica.Normal);
  Alcotest.(check int) "nothing was dropped: CompletionPoint is the winner's own n" 2 (Replica.op_number t);
  Alcotest.(check bool) "op 1 was reconstructed from the peer, op 2 from the winner" true
    (Replica.entries t = [ v "a"; v "b" ]);
  Alcotest.(check bool) "the repaired log is durable on the new primary" true
    (Replica.for_test_wal_read t ~op_number:1 = Some (v "a")
    && Replica.for_test_wal_read t ~op_number:2 = Some (v "b"));
  Alcotest.(check bool) "StartView carries the repaired log" true
    (List.for_all
       (fun (_, m) -> m = Message.Start_view { v = 5; log = [ v "a"; v "b" ]; n = 2; k = 1 })
       (decoded_sent sent))

(* The other half of the same rule: a DVC from a LOWER log_view is NOT an admissible source
   (VSR.tla:438-439 -- "those may be superseded values from an abandoned view"), so it cannot
   unblock a completion, and the coordinator must wait rather than adopt it. *)
let test_a_lower_log_view_dvc_is_not_an_admissible_entry_source () =
  let send, sent = capturing_send () in
  let _backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.for_test_set_view t ~status:Replica.View_change ~view_number:5 ~last_normal_view:2;
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:[ (2, v "b") ] ~nacks:[] ~last_normal_view:3 ~n:2 ~k:0 ~i:1);
  (* Same op 1 on offer as the test above, but from log_view 2 < the winner's 3. *)
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:[ (1, v "stale") ] ~nacks:[] ~last_normal_view:2 ~n:2 ~k:0 ~i:3);
  Alcotest.(check (list int)) "a full f+1 = 2 quorum is present" [ 1; 3 ] (Replica.for_test_recv_dvc_senders t);
  Alcotest.(check bool) "no completion: op 1 has no admissible source and no nack quorum" true
    (Replica.status t = Replica.View_change);
  Alcotest.(check bool) "and nothing was broadcast" true (sent () = [])

(* Adversarial-input regression: a DVC whose [n] is absurd must not make the completion
   arithmetic walk the op-number space. *)
let test_forged_huge_n_does_not_hang () =
  let send, _sent = capturing_send () in
  let _backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.for_test_set_view t ~status:Replica.View_change ~view_number:5 ~last_normal_view:2;
  (* The winner claims an absurd op-number, and the OTHER f+1 = 2 senders structurally prove every
     op above their own [n] absent -- so every op from 1_000_000_000 down to 2 really IS
     proven-absent evidence the completion arithmetic would have to consider. A scan over that
     range is a hang, not a slow path. *)
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:[ (1, v "a") ] ~nacks:[] ~last_normal_view:2 ~n:1_000_000_000 ~k:0 ~i:1);
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:[ (1, v "a") ] ~nacks:[] ~last_normal_view:2 ~n:1 ~k:0 ~i:2);
  Replica.handle_message t
    (dvc_msg ~v:5 ~entries:[ (1, v "a") ] ~nacks:[] ~last_normal_view:2 ~n:1 ~k:0 ~i:3);
  (* It completes, at CompletionPoint = 1: op 1 is fillable, and every op above it is proven
     absent by the two honest senders. The point of the test is that it gets there in constant
     time rather than by walking 10^9 op-numbers. *)
  Alcotest.(check bool) "the forged DVC did not wedge or hang the completion" true (Replica.status t = Replica.Normal);
  Alcotest.(check int) "completed at the only op anyone can actually supply" 1 (Replica.op_number t)

(* VSR.tla:282-291's storage-fault-aware addition to the NORMAL path: [PrimaryExecuteOp] requires
   [Holds(r, next)] -- the primary must be able to READ the entry it is about to execute. Counting
   itself toward the f+1 while its own copy is unreadable would let a cluster commit with only f
   readable copies. *)
let test_primary_does_not_commit_an_op_it_cannot_read () =
  let send, _sent = capturing_send () in
  let backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.for_test_set_view t ~status:Replica.Normal ~view_number:1 ~last_normal_view:1;
  Alcotest.(check bool) "this replica is Primary(1)" true (Replica.is_primary t);
  Replica.propose t (v "a");
  Alcotest.(check int) "proposed, not yet committed" 0 (Replica.commit_number t);
  (* Its own durable copy faults before the acks arrive. *)
  Riptide_storage.Memory_storage.for_test_corrupt backend ~op_number:1;
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 2 }));
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 3 }));
  Alcotest.(check int)
    "NOT committed: an f+1 quorum that counts an unreadable copy is only f readable copies" 0
    (Replica.commit_number t)

(* The [restart] reconciliation VSR.tla does not need but a real WAL does: a crash between
   [wal_append] and the superblock write leaves an entry on disk the durable op-number does not
   know about. It was never acknowledged (the PrepareOk goes out only after both writes), so it is
   discarded — and discarding it is what restores the [wal_highest_op_number = op_number]
   agreement every later append depends on. Without it the replica looks fine and then silently
   drops every subsequent Prepare, forever. *)
let test_restart_discards_wal_entries_the_superblock_never_saw () =
  let send, _sent = capturing_send () in
  let backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Alcotest.(check int) "one durable, acknowledged entry" 1 (Replica.op_number t);
  (* The torn write: op 2's bytes landed, the superblock update did not. *)
  Riptide_storage.Memory_storage.wal_append backend ~op_number:2 "never acknowledged";
  Alcotest.(check int) "the backend is now one ahead of the superblock" 2
    (Riptide_storage.Memory_storage.wal_highest_op_number backend);
  let send2, sent2 = capturing_send () in
  let storage2 = Replica.storage_of_module (module Riptide_storage.Memory_storage) backend in
  let t' = Replica.restart ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send:send2 ~storage:storage2 in
  Alcotest.(check int) "op_number is the superblock's, not the WAL's" 1 (Replica.op_number t');
  Alcotest.(check int) "the unacknowledged entry was discarded" 1
    (Riptide_storage.Memory_storage.wal_highest_op_number backend);
  (* The real consequence: the replica can still take part in the protocol afterwards. *)
  Replica.handle_message t' (Message.encode (Message.Prepare { view = 0; n = 2; v = v "b"; k = 0 }));
  Alcotest.(check int) "the next legitimate Prepare is accepted" 2 (Replica.op_number t');
  Alcotest.(check bool) "and acknowledged" true
    (List.exists (fun (_, m) -> m = Message.Prepare_ok { view = 0; n = 2; i = 1 }) (decoded_sent sent2));
  Alcotest.(check bool) "with the right value durably stored" true
    (Replica.for_test_wal_read t' ~op_number:2 = Some (v "b"))

(* ============================================================================================
   FINAL-REVIEW FINDING C1: a lost superblock over a NON-EMPTY WAL must be FAIL-STOP.

   THE DEFECT THESE PIN. [restart] used to fall back to [(view, last_normal_view, op_number,
   commit_number) = (0, 0, 0, 0)] whenever the superblock did not read back, and then truncate the
   WAL down to match [op_number = 0] -- even with the WAL itself fully intact on disk. The replica
   came back reporting [n = 0] in its DoViewChange, and [sender_proves_absent] treats every op above
   a sender's own [n] as PROVABLY ABSENT (replica.ml:1091), so that replica proceeded to prove
   absent every op it had ever durably held. Two such replicas (or one plus one honest nack) are a
   nack quorum, which truncates a committed, client-acknowledged value cluster-wide.

   That is not a hypothetical: it is exactly the mutation spec/tla/VSR.tla:111-150 records TLC
   refuting -- one word, "corrupt" to "absent", so a restart may discover a durably-written slot
   provably empty, violating [NoCommittedOpProvablyAbsent] at depth 6. The fallback was that
   mutation, in OCaml, reachable from an ORDINARY crash with no injected fault: [superblock_write]
   is 3 sequential, non-atomic copy writes, and a crash between any copy's header and data write
   leaves fewer than 2 copies agreeing, which is precisely when [superblock_read] returns [None].

   THE FIX these three tests pin, from both sides: [restart] REFUSES (fail-stop, [Invalid_argument],
   matching [create]'s own convention for its own precondition violations) when the superblock is
   unusable while the WAL is non-empty -- and STILL accepts the genuinely empty backend, which is
   the legitimate first-boot case and must keep working. *)

let restart_refusal_message =
  "Replica.restart: this backend's superblock is unreadable while its WAL is NOT empty -- refusing \
   to start. Coming up with op_number = 0 over a WAL that still holds entries would make this \
   replica prove absent (VSR.tla's CanNack) every op it durably held, which a nack quorum turns \
   into cluster-wide loss of committed data (VSR.tla:111-150). The durable log is intact and \
   untouched; recovering this replica needs the superblock rebuilt or the backend discarded \
   wholesale, neither of which restart can decide on its own."

(* A replica with two durable entries, one of them committed, whose superblock then goes missing
   entirely -- [superblock_read] returning [None], the exact shape [File_storage] produces when
   fewer than 2 of its 3 copies verify and agree. *)
let test_restart_refuses_a_lost_superblock_over_a_non_empty_wal () =
  let send, _sent = capturing_send () in
  let backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 2; v = v "b"; k = 1 }));
  Alcotest.(check int) "precondition: op 1 is committed and durable" 1 (Replica.commit_number t);
  Riptide_storage.Memory_storage.for_test_lose_superblock backend;
  Alcotest.(check bool) "precondition: the superblock really is gone" true
    (Riptide_storage.Memory_storage.superblock_read backend = None);
  Alcotest.(check bool) "precondition: the WAL really is intact" true
    (Riptide_storage.Memory_storage.wal_highest_op_number backend = 2);
  let send2, _sent2 = capturing_send () in
  let storage2 = Replica.storage_of_module (module Riptide_storage.Memory_storage) backend in
  Alcotest.check_raises "restart refuses rather than coming up at op_number = 0"
    (Invalid_argument restart_refusal_message) (fun () ->
      ignore (Replica.restart ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send:send2 ~storage:storage2));
  (* THE REFUSAL IS A TOTAL NO-OP on durable state, which is what makes it a recoverable failure
     rather than a differently-shaped data loss: the WAL is not truncated, and the committed entry
     is still there to be recovered by whatever rebuilds the superblock. *)
  Alcotest.(check int) "the WAL was NOT truncated by the refused restart" 2
    (Riptide_storage.Memory_storage.wal_highest_op_number backend);
  Alcotest.(check bool) "and the committed entry is still durably readable" true
    (Riptide_storage.Memory_storage.wal_read backend ~op_number:1
    = Some (Value.canonical_encode (v "a")))

(* The second shape of "unusable superblock", and it must be treated identically: the record reads
   back fine at the storage layer but does not decode as this module's own superblock record
   ([superblock_decode] returns [None]). A partially-decodable superblock is no more trustworthy
   than a missing one -- that is already [superblock_decode]'s own documented stance -- so it must
   reach the same fail-stop, not the same silent zero-fallback. *)
let test_restart_refuses_an_undecodable_superblock_over_a_non_empty_wal () =
  let send, _sent = capturing_send () in
  let backend, storage = fresh_storage () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Riptide_storage.Memory_storage.superblock_write backend "not a superblock record at all";
  Alcotest.(check bool) "precondition: storage hands back bytes, they just are not usable" true
    (Riptide_storage.Memory_storage.superblock_read backend <> None);
  let send2, _sent2 = capturing_send () in
  let storage2 = Replica.storage_of_module (module Riptide_storage.Memory_storage) backend in
  Alcotest.check_raises "an undecodable superblock is refused exactly like a missing one"
    (Invalid_argument restart_refusal_message) (fun () ->
      ignore (Replica.restart ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send:send2 ~storage:storage2))

(* THE OTHER SIDE OF THE GUARD, and the reason it is conditioned on the WAL rather than on the
   superblock alone: first boot. A genuinely empty backend -- no superblock, no WAL -- is not a
   lost superblock, it is a replica that has never run, and it must still come up as [Init]
   exactly as {!Replica.create} would. A guard that refused on "no superblock" alone would make
   [restart] unusable as a general entry point. *)
let test_restart_still_accepts_a_genuinely_empty_backend () =
  let send, _sent = capturing_send () in
  let _backend, storage = fresh_storage () in
  let t = Replica.restart ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send ~storage in
  Alcotest.(check int) "Init: view_number" 0 (Replica.view_number t);
  Alcotest.(check int) "Init: last_normal_view" 0 (Replica.last_normal_view t);
  Alcotest.(check int) "Init: op_number" 0 (Replica.op_number t);
  Alcotest.(check int) "Init: commit_number" 0 (Replica.commit_number t);
  Alcotest.(check bool) "Init: status" true (Replica.status t = Replica.Normal);
  Alcotest.(check bool) "Init: empty log" true (Replica.entries t = []);
  (* And it is a WORKING replica, not merely a constructed one. *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Alcotest.(check int) "it accepts a Prepare like any freshly created replica" 1 (Replica.op_number t)

(* ============================================================================================
   TASK 8: the CLUSTER-level half -- recovery under REAL injected storage faults.

   Everything above this line drives ONE replica with hand-built messages. That proves each action
   in isolation and nothing about whether a real cluster of real, running replicas, talking over a
   real (simulated) transport, actually survives a storage fault on one of them. This section is
   that proof, by running the code -- the same relationship test_vsr_replica_view_change.ml has to
   test_vsr_replica.ml, and the same discipline this repo's own CLAUDE.md ("no spec without running
   code") demands of the recovery extension as a whole.

   WHY [Memory_storage] UNDER THE WRAPPER, NOT [File_storage] (the brief left this call open):
   the harness runs under [Eio_mock.Backend.run], a scheduler with no filesystem capability at all;
   [File_storage.create] needs a real [~fs] (and an [Eio_main.run]/io_uring scope), so using it here
   would mean restructuring the cluster harness around a real event loop purely to obtain a value
   whose ON-DISK behaviour these tests never assert. What these tests assert is PROTOCOL behaviour
   under a storage fault, and [Memory_storage] is a real [Storage_intf.S] implementation for that
   purpose, not a stub -- it is run against test/test_storage_shared.ml's shared conformance suite
   alongside [File_storage] and [Fault_injecting_storage] itself. The claim that
   [for_test_corrupt_entry] really reaches the DURABLE representation is proven separately, against
   a real [File_storage] on a real disk, in test_fault_injecting_storage.ml
   ([test_for_test_corrupt_entry_really_corrupts_the_durable_entry], which reads the corrupted
   bytes back through the underlying [File_storage] directly, bypassing the wrapper's own mask).
   Using [Memory_storage] here also sidesteps [File_storage]'s [ring_capacity] sizing entirely
   (Task 7's report flags the default of 8 as something a scenario with more ops must size for);
   these scenarios use 3 ops, but the harness would have had to pick a number regardless. *)

exception Cluster_test_done
(* Unwinds the outer Eio.Switch.run once a test body is done -- same mechanism (and, deliberately,
   the same name, in a different module, so there is no clash) as
   test_vsr_replica_view_change.ml's own. *)

exception Replica_stopped
(* Unwinds exactly ONE replica's own inner Eio.Switch.run: {!with_cluster_and_storage}'s [stop]. *)

(* [with_cluster_and_storage ~replica_count ~svc_limit body] is test_vsr_replica_view_change.ml's
   own [with_cluster], followed faithfully -- same Network/Sim_transport wiring, same
   [Network.default_fault_config] (no NETWORK faults here at all: the faults under test are
   STORAGE faults, and a lost DoViewChange would confound the scenario exactly as that file's own
   forward note 1 explains), same view pinning to 1 so Primary(1) = 1, same per-replica
   [Eio.Switch.run] + [Replica_stopped] crash simulation, same bounded-round [settle] pump, same
   send-side [isolate]/[reconnect] partition -- plus ONE addition: each replica's durable backend
   is its own fresh [Fault_injecting_storage.t] (wrapping its own fresh [Memory_storage.t]), and
   those wrappers are handed to [body] as [storages], so a test can inject a REAL fault into ONE
   named replica's ONE named op-number mid-run.

   A local wrapper rather than a change to that file's already-reviewed [with_cluster]: the two
   differ only in how storage is constructed, and this suite's convention is that each
   cluster-level test file is self-contained (test_vsr_replica_view_change.ml does not import
   test_vsr_replica_cluster.ml's harness either, for the same reason).

   [storages.(i)] is replica [i + 1]'s -- same index convention as [replicas]. *)
let with_cluster_and_storage ~replica_count ~svc_limit
    (body :
      replicas:Replica.t array ->
      storages:Riptide_storage.Fault_injecting_storage.t array ->
      stop:(int -> unit) ->
      settle:(unit -> unit) ->
      isolate:(int -> unit) ->
      reconnect:(int -> unit) ->
      unit) =
  Eio_mock.Backend.run @@ fun () ->
  let prng = Riptide_sim.Prng.create 1 in
  let net = Riptide_sim.Network.create prng () (* faults default to Network.default_fault_config *) in
  for id = 1 to replica_count do
    Riptide_sim.Network.register net (string_of_int id)
  done;
  let handles = Array.init replica_count (fun i -> Riptide_sim.Sim_transport.create net (i + 1)) in
  let isolated = Array.make (replica_count + 1) false in
  (* VSR's own replication quorum, f + 1 (VSR.tla:140's [f = (ReplicaCount-1) \div 2]) -- the value
     Fault_injecting_storage's Decision 7 cap is stated against. Each replica gets its OWN wrapper
     over its OWN backend, so the cap is per-replica: at replica_count = 3 that is faults_max = 1,
     i.e. one live corrupted slot per replica, which is exactly the fault budget a 3-replica
     cluster is supposed to survive. *)
  let replication_quorum = ((replica_count - 1) / 2) + 1 in
  let storages =
    Array.init replica_count (fun i ->
        (* A separate, per-replica Prng seed, deliberately NOT the network's own [prng]: sharing it
           would make every storage decision consume draws from the same stream the network's
           delivery/fault decisions come from, so adding a storage fault to a test would silently
           shift the whole network schedule. Reproducible either way, but only this way is the
           network schedule stable across tests that inject different storage faults. *)
        Riptide_storage.Fault_injecting_storage.create
          ~prng:(Riptide_sim.Prng.create (100 + i))
          ~replication_quorum
          ~underlying:(module Riptide_storage.Memory_storage)
          (Riptide_storage.Memory_storage.create ()))
  in
  let replicas =
    Array.init replica_count (fun i ->
        let my_id = i + 1 in
        let r =
          Replica.create
            ~storage:(Replica.storage_of_module (module Riptide_storage.Fault_injecting_storage) storages.(i))
            ~my_id ~replica_count ~svc_limit
            ~send:(fun ~to_ bytes -> if isolated.(to_) then () else Riptide_sim.Sim_transport.send handles.(i) ~to_ bytes)
        in
        Replica.for_test_set_view_number r 1;
        r)
  in
  let isolate i = isolated.(i) <- true in
  let reconnect i = isolated.(i) <- false in
  let settle () =
    let rec loop rounds_left =
      if rounds_left <= 0 then Alcotest.fail "cluster did not quiesce within the round budget -- possible non-termination"
      else begin
        let delivered = ref false in
        while Riptide_sim.Network.pump_one net do
          delivered := true
        done;
        Eio.Fiber.yield ();
        Eio.Fiber.yield ();
        if !delivered then loop (rounds_left - 1)
      end
    in
    loop 20
  in
  let stop_fns = Array.make replica_count None in
  try
    Eio.Switch.run (fun sw ->
        Array.iteri
          (fun i replica ->
            Eio.Fiber.fork ~sw (fun () ->
                try
                  Eio.Switch.run (fun replica_sw ->
                      stop_fns.(i) <- Some (fun () -> Eio.Switch.fail replica_sw Replica_stopped);
                      let rec dispatch_loop () =
                        let msg = Riptide_sim.Sim_transport.receive handles.(i) in
                        Replica.handle_message replica msg;
                        dispatch_loop ()
                      in
                      dispatch_loop ())
                with Replica_stopped -> ()))
          replicas;
        let stop i =
          match stop_fns.(i - 1) with
          | Some f -> f ()
          | None ->
            Alcotest.fail
              (Printf.sprintf
                 "stop %d called before replica %d's dispatch fiber had registered its own stop function -- call \
                  settle () at least once before the first stop () in this test"
                 i i)
        in
        body ~replicas ~storages ~stop ~settle ~isolate ~reconnect;
        Eio.Switch.fail sw Cluster_test_done)
  with Cluster_test_done -> ()

(* Same helper, and same reasoning, as test_vsr_replica_view_change.ml's own: several replicas'
   timers must fire INDEPENDENTLY (no yields in between) for a 3-replica cluster's two survivors to
   each broadcast their own StartViewChange, which is what gets EXACTLY f + 1 = 2 DoViewChanges to
   the new primary. Every call after the first is a real, guard-enforced no-op. *)
let fire_check_timeout_repeatedly r ~times =
  for _ = 1 to times do
    Replica.check_timeout r
  done

(* --------------------------------------------------------------------------------------------
   Test 1 (the plan's own scenario): a value that is genuinely COMMITTED cluster-wide, one
   replica's durable copy of it destroyed for real, the primary crashed, and the view change forced
   through the corrupted replica -- which, at view 2 with replica_count = 3, is itself the NEW
   PRIMARY (Primary(2) = 2). That is the demanding placement, not an incidental one: the
   coordinator of the recovery is the replica that cannot read the committed entry it has to
   install, so completing the view change REQUIRES filling op 1 from a peer's DoViewChange
   (EntrySources/CanFill/FillValue, VSR.tla:440-444) rather than from its own storage.

   What would happen WITHOUT Task 7's recovery logic, i.e. why this is not vacuous: the pre-Task-7
   SendSV adopted [winner.log] wholesale, where the winner's log was its own in-memory [entries].
   It had no notion of an unreadable slot at all, so the corruption would have been invisible here
   and the test would prove nothing. With the storage-aware version, replica 2's own DoViewChange
   genuinely ships only op 2 (op 1 is Corrupt, and a corrupt slot is NEVER shipped and NEVER
   nacked), so op 1 must come from replica 3 or the view change cannot complete at all. *)
let test_cluster_recovers_a_committed_entry_from_one_replicas_corrupted_storage () =
  with_cluster_and_storage ~replica_count:3 ~svc_limit:3 (fun ~replicas ~storages ~stop ~settle ~isolate:_ ~reconnect:_ ->
      let old_primary = replicas.(0) (* my_id = 1, Primary(1) = 1 *) in
      let corrupted = replicas.(1) (* my_id = 2, and Primary(2) = 2: the NEW primary *) in
      let healthy = replicas.(2) in
      let v1 = v "must survive corruption" and v2 = v "the follow-up that piggybacks k = 1" in
      (* Two proposes, each settled: the second's Prepare carries k = 1, which is what actually
         advances the BACKUPS' own commit_number to 1 (test_vsr_replica_cluster.ml's own precedent
         -- a backup never commits from the replication of v1 itself). *)
      Replica.propose old_primary v1;
      settle ();
      Replica.propose old_primary v2;
      settle ();
      Alcotest.(check bool) "v1 is committed on all three replicas before any fault" true
        (Replica.is_committed old_primary v1 && Replica.is_committed corrupted v1 && Replica.is_committed healthy v1);
      Alcotest.(check bool) "and it is genuinely DURABLE on the replica about to be corrupted" true
        (Replica.for_test_wal_read corrupted ~op_number:1 = Some v1);
      (* THE FAULT: replica 2's durable copy of the committed op 1 is destroyed for real, through
         the underlying backend's own machinery -- not simulated by poking the replica's fields. *)
      Riptide_storage.Fault_injecting_storage.for_test_corrupt_entry storages.(1) ~op_number:1;
      Alcotest.(check bool) "the injected fault is REAL: replica 2 can no longer read op 1 at all" true
        (Replica.for_test_wal_read corrupted ~op_number:1 = None);
      Alcotest.(check int) "and it is CORRUPT, not ABSENT -- the durable op_number is untouched" 2
        (Replica.op_number corrupted);
      Alcotest.(check bool) "op 2 next to it is unaffected" true (Replica.for_test_wal_read corrupted ~op_number:2 = Some v2);
      (* THE CRASH, and the view change forced through the corrupted replica. *)
      stop 1;
      fire_check_timeout_repeatedly corrupted ~times:4;
      fire_check_timeout_repeatedly healthy ~times:4;
      settle ();
      Alcotest.(check int) "the survivors reached view 2" 2 (Replica.view_number corrupted);
      Alcotest.(check int) "both of them" 2 (Replica.view_number healthy);
      Alcotest.(check bool) "Primary(2) = 2: the CORRUPTED replica is the new primary" true (Replica.is_primary corrupted);
      Alcotest.(check bool) "the view change actually completed on the new primary" true (Replica.status corrupted = Replica.Normal);
      Alcotest.(check bool) "and on the other survivor" true (Replica.status healthy = Replica.Normal);
      (* THE POINT: the committed entry is back, on the replica whose own copy was destroyed. *)
      Alcotest.(check bool) "the new primary's log holds the recovered v1 and v2, in order" true
        (Replica.entries corrupted = [ v1; v2 ]);
      Alcotest.(check bool) "v1 is still committed on the new primary despite its copy having been destroyed" true
        (Replica.is_committed corrupted v1);
      Alcotest.(check bool) "and on the other survivor" true (Replica.is_committed healthy v1);
      (* ...and the repair is DURABLE, not merely in memory: the slot that read back [None] a moment
         ago now reads back the real committed value again, because the completion rewrote it. *)
      Alcotest.(check bool) "the destroyed slot was durably REPAIRED on the new primary's own storage" true
        (Replica.for_test_wal_read corrupted ~op_number:1 = Some v1);
      Alcotest.(check bool) "the healthy survivor's storage is intact too" true
        (Replica.for_test_wal_read healthy ~op_number:1 = Some v1
        && Replica.for_test_wal_read healthy ~op_number:2 = Some v2);
      (* The cluster is not merely consistent, it WORKS: the new primary can serve a new proposal. *)
      let v3 = v "proposed after the recovery" in
      Replica.propose corrupted v3;
      settle ();
      Alcotest.(check bool) "the recovered cluster accepts and replicates a new proposal" true
        (Replica.entries healthy = [ v1; v2; v3 ]))

(* --------------------------------------------------------------------------------------------
   Test 2: the SAME scenario, but no longer dependent on which of the two DoViewChanges wins the
   tie -- see the correction below on why test 1 is not actually dependent on that either.

   Both survivors report the same [(last_normal_view, n) = (1, 2)], so [WinningDVC]'s maximum is a
   TIE. This is NOT resolved by hashtable fold order: [valid_dvcs] (replica.ml:942-944) sorts its
   result by sender id specifically so the fold in [winning_dvc] is reproducible, and that fold
   keeps the incumbent on a strict-inequality tie, so an exact [(last_normal_view, n)] tie resolves
   deterministically to the LOWEST sender id (replica.ml:956-957). In test 1 the two survivors are
   replicas 2 and 3 (replica 2's DVC to itself is in its own [recv_dvc] too), so replica 2 -- the
   corrupted one -- deterministically wins every run, and test 1 always exercises the cross-replica
   fill, not merely when the build/hashtable happens to order things that way.

   So test 2 is not closing a present nondeterminism gap; it is defense against a FUTURE change to
   that tie-break rule (e.g. if the sort or the comparison in [winning_dvc] is ever altered) making
   test 1 vacuous again without anyone noticing. Here NEITHER survivor has a complete readable log
   -- replica 2 cannot read op 1, replica 3 cannot read op 2 -- so whichever one wins, the other's
   entry is the ONLY source for the missing op, and the completion is impossible without genuinely
   unioning evidence across the quorum, regardless of which way the tie-break resolves now or ever
   resolves in the future. One live corrupted slot per replica is exactly the Decision 7 budget
   ([faults_max = replication_quorum - 1 = 1] per storage) a 3-replica cluster is meant to absorb.

   This is also the shape that makes the whole thing fail under a mutation: neutering the fill so a
   missing op can only come from the winner makes this test fail for BOTH tie orders, not one. *)
let test_cluster_recovers_when_no_single_survivor_holds_a_complete_readable_log () =
  with_cluster_and_storage ~replica_count:3 ~svc_limit:3 (fun ~replicas ~storages ~stop ~settle ~isolate:_ ~reconnect:_ ->
      let old_primary = replicas.(0) in
      let survivor2 = replicas.(1) and survivor3 = replicas.(2) in
      let v1 = v "op 1, unreadable on replica 2" and v2 = v "op 2, unreadable on replica 3" in
      Replica.propose old_primary v1;
      settle ();
      Replica.propose old_primary v2;
      settle ();
      Alcotest.(check bool) "v1 committed everywhere before the faults" true
        (Replica.is_committed survivor2 v1 && Replica.is_committed survivor3 v1);
      (* Complementary faults, one per survivor -- each within its own storage's faults_max = 1. *)
      Riptide_storage.Fault_injecting_storage.for_test_corrupt_entry storages.(1) ~op_number:1;
      Riptide_storage.Fault_injecting_storage.for_test_corrupt_entry storages.(2) ~op_number:2;
      Alcotest.(check bool) "replica 2 holds only op 2 readably" true
        (Replica.for_test_wal_read survivor2 ~op_number:1 = None && Replica.for_test_wal_read survivor2 ~op_number:2 = Some v2);
      Alcotest.(check bool) "replica 3 holds only op 1 readably" true
        (Replica.for_test_wal_read survivor3 ~op_number:1 = Some v1 && Replica.for_test_wal_read survivor3 ~op_number:2 = None);
      stop 1;
      fire_check_timeout_repeatedly survivor2 ~times:4;
      fire_check_timeout_repeatedly survivor3 ~times:4;
      settle ();
      Alcotest.(check bool) "the view change completed even though NO survivor could read the whole log" true
        (Replica.status survivor2 = Replica.Normal && Replica.status survivor3 = Replica.Normal);
      Alcotest.(check bool) "the new primary reconstructed the full log from the quorum's combined evidence" true
        (Replica.entries survivor2 = [ v1; v2 ]);
      Alcotest.(check bool) "so did the other survivor, via StartView" true (Replica.entries survivor3 = [ v1; v2 ]);
      Alcotest.(check bool) "the committed entry survived on both" true
        (Replica.is_committed survivor2 v1 && Replica.is_committed survivor3 v1);
      (* Both replicas' destroyed slots are durably repaired -- replica 2's by its own completion
         ([SendSV]'s [adopt_durable_log]), replica 3's by adopting the resulting StartView. *)
      Alcotest.(check bool) "replica 2's destroyed op 1 is durably repaired" true
        (Replica.for_test_wal_read survivor2 ~op_number:1 = Some v1);
      Alcotest.(check bool) "replica 3's destroyed op 2 is durably repaired" true
        (Replica.for_test_wal_read survivor3 ~op_number:2 = Some v2))

(* --------------------------------------------------------------------------------------------
   Test 3: the OTHER half -- an op that never reaches quorum commits NOWHERE, when the reason it
   cannot reach quorum is a storage fault rather than a dead peer.

   The plain "never reaches quorum" case (both backups crashed, no acks at all) is already covered,
   at cluster level, by test_batch_commit_cluster.ml's own
   [test_batch_that_never_reached_quorum_is_absent_everywhere] -- not duplicated here. What is NOT
   covered anywhere is the storage-fault version of it: a primary that receives a FULL f + 1 = 2
   worth of acks but cannot READ its own copy of the op it is about to execute. VSR.tla:282-291's
   storage-aware [PrimaryExecuteOp] requires [Holds(r, next)] for exactly this reason -- counting
   itself toward the quorum while its own copy is unreadable would let the cluster commit with only
   f readable copies. test_primary_does_not_commit_an_op_it_cannot_read above pins that on a single
   hand-driven replica; this pins the CLUSTER-visible consequence: nothing, anywhere, ever reports
   it committed, and no later traffic quietly upgrades it. *)
let test_an_op_the_primary_cannot_read_commits_nowhere_in_the_cluster () =
  with_cluster_and_storage ~replica_count:3 ~svc_limit:3 (fun ~replicas ~storages ~stop:_ ~settle ~isolate:_ ~reconnect:_ ->
      let primary = replicas.(0) in
      let v1 = v "committed normally" and v2 = v "the op the primary loses its own copy of" in
      Replica.propose primary v1;
      settle ();
      Alcotest.(check int) "the primary committed op 1 normally" 1 (Replica.commit_number primary);
      (* Propose, then destroy the primary's own copy BEFORE the acks are ever processed: [propose]
         only queues its Prepares in the network, and nothing is delivered until [settle] pumps. *)
      Replica.propose primary v2;
      Riptide_storage.Fault_injecting_storage.for_test_corrupt_entry storages.(0) ~op_number:2;
      settle ();
      Alcotest.(check bool) "both backups DID durably store and acknowledge it" true
        (Replica.for_test_wal_read replicas.(1) ~op_number:2 = Some v2
        && Replica.for_test_wal_read replicas.(2) ~op_number:2 = Some v2);
      Alcotest.(check int) "yet the primary's commit_number never advanced past op 1" 1 (Replica.commit_number primary);
      Alcotest.(check bool) "it is committed NOWHERE in the cluster -- not even on the replicas that hold it" true
        ((not (Replica.is_committed primary v2))
        && (not (Replica.is_committed replicas.(1) v2))
        && not (Replica.is_committed replicas.(2) v2));
      (* ...and the earlier, genuinely committed op is untouched by the neighbouring fault. *)
      Alcotest.(check bool) "op 1 is still committed everywhere" true
        (Replica.is_committed primary v1 && Replica.is_committed replicas.(1) v1 && Replica.is_committed replicas.(2) v1))

let tests =
  [
    ("a forged, absurd DVC n does not make completion walk the op-number space", `Quick, test_forged_huge_n_does_not_hang);
    ( "a primary never commits an op its own storage cannot read",
      `Quick,
      test_primary_does_not_commit_an_op_it_cannot_read );
    ( "restart discards WAL entries the superblock never saw, and stays usable",
      `Quick,
      test_restart_discards_wal_entries_the_superblock_never_saw );
    ( "Review Focus: wal_truncate_after below commit_number is rejected",
      `Quick,
      test_truncate_wal_below_commit_number_is_rejected );
    ("Review Focus: an out-of-range nack is a total no-op, never a crash", `Quick, test_out_of_range_nack_is_a_total_no_op);
    ( "HasDvcQuorum counts distinct senders, not messages",
      `Quick,
      test_dvc_quorum_counts_distinct_senders_not_messages );
    ( "a contested op blocks completion until a nack quorum proves it absent",
      `Quick,
      test_contested_op_blocks_completion_then_a_nack_quorum_resolves_it );
    ("ForfeitViewChange fires on a quorum that cannot complete", `Quick, test_forfeit_view_change_when_quorum_cannot_complete);
    ("ForfeitViewChange is NOT enabled below a DVC quorum", `Quick, test_no_forfeit_below_a_dvc_quorum);
    ("a corrupt slot is neither shipped as an entry nor nacked", `Quick, test_corrupt_slot_is_neither_shipped_nor_nacked);
    ( "CrashRestart: durable state survives, volatile state is lost, status is reconstructed",
      `Quick,
      test_restart_preserves_durable_state_and_reconstructs_view_change_status );
    ( "CrashRestart outside a view change reconstructs Normal",
      `Quick,
      test_restart_outside_a_view_change_reconstructs_normal_status );
    ( "a slot discovered corrupt at restart is still never nacked",
      `Quick,
      test_restart_discovering_a_corrupt_slot_still_refuses_to_nack_it );
    ( "readable entries are a partial map, not merely a readable prefix",
      `Quick,
      test_readable_entries_are_not_merely_a_prefix );
    ( "an entry the winner cannot read is filled from a same-log_view peer",
      `Quick,
      test_an_unreadable_winner_entry_is_filled_from_a_same_log_view_peer );
    ( "a lower-log_view DVC is not an admissible entry source",
      `Quick,
      test_a_lower_log_view_dvc_is_not_an_admissible_entry_source );
    ( "C1: restart REFUSES a lost superblock over a non-empty WAL (fail-stop, not op_number = 0)",
      `Quick,
      test_restart_refuses_a_lost_superblock_over_a_non_empty_wal );
    ( "C1: an undecodable superblock over a non-empty WAL is refused identically",
      `Quick,
      test_restart_refuses_an_undecodable_superblock_over_a_non_empty_wal );
    ( "C1: a genuinely empty backend still restarts cleanly as Init (first boot keeps working)",
      `Quick,
      test_restart_still_accepts_a_genuinely_empty_backend );
    ( "CLUSTER: a committed entry survives real injected corruption of one replica's copy",
      `Quick,
      test_cluster_recovers_a_committed_entry_from_one_replicas_corrupted_storage );
    ( "CLUSTER: recovery works when no single survivor holds a complete readable log",
      `Quick,
      test_cluster_recovers_when_no_single_survivor_holds_a_complete_readable_log );
    ( "CLUSTER: an op the primary cannot read commits nowhere, not even partially",
      `Quick,
      test_an_op_the_primary_cannot_read_commits_nowhere_in_the_cluster );
  ]
