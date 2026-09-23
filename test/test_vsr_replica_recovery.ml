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
  ]
