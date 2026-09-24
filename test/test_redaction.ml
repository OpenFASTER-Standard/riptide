(* test/test_redaction.ml -- Task 6 of the lattice-materialization-redaction-encryption plan
   (.superpowers/sdd/2026-09-23-lattice-materialization-redaction-encryption/): the redaction
   keystore (envelope encryption via independent per-record DEKs wrapped under a shared KEK,
   design spec Decision 4), KEK file sourcing (Decision 5), and the real wiring of both into
   this codebase's own content-hashed write path.

   The load-bearing invariant every test below exists to pin down: an envelope's own
   [Riptide.Envelope.content_hash] is computed over CIPHERTEXT, never plaintext. That is what
   makes crypto-shredding redaction work at all -- deleting a keystore entry destroys
   recoverability without ever touching, recomputing, or even reading the content-addressed
   envelope, so the hash chain is bit-identical before and after a redaction. *)

open Riptide_crypto
open Riptide_batch_commit
open Riptide_vsr

let () = Mirage_crypto_rng_unix.use_default ()

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_redaction_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

(* [Kek.of_raw] is the test-only constructor, for a KEK already in memory; [Kek.load ~path] is the
   real one every deployment uses, tested separately below. *)
let with_store f =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv =
        Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore"
          dir
      in
      let kek = Kek.of_raw (Mirage_crypto_rng.generate 32) in
      f (Redaction_store.create ~kv ~kek))

(* ---- the keystore itself ---- *)

let test_encrypt_then_decrypt () =
  with_store (fun store ->
      let v = Riptide.Value.Scalar (Riptide.Value.String "sensitive") in
      let ct = Redaction_store.encrypt_for_storage store ~event_id:"e1" v in
      Alcotest.(check bool) "decrypts back to the original" true
        (Redaction_store.decrypt store ~event_id:"e1" ct = Some v))

let test_ciphertext_does_not_contain_the_plaintext () =
  with_store (fun store ->
      let v = Riptide.Value.Scalar (Riptide.Value.String "plaintext-marker") in
      let ct = Redaction_store.encrypt_for_storage store ~event_id:"e1" v in
      Alcotest.(check bool) "ciphertext does not contain the plaintext bytes" false
        (try
           ignore (Str.search_forward (Str.regexp_string "plaintext-marker") ct 0);
           true
         with Not_found -> false))

let test_content_hash_of_ciphertext_is_stable_across_redaction () =
  (* This is the whole point of Decision 4: the envelope's own content_hash covers ciphertext
     only, so redaction (deleting the keystore entry) must never change it. *)
  with_store (fun store ->
      let v = Riptide.Value.Scalar (Riptide.Value.String "sensitive") in
      let ct = Redaction_store.encrypt_for_storage store ~event_id:"e1" v in
      let hash_before = Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.Bytes ct)) in
      Redaction_store.redact store ~event_id:"e1";
      let hash_after = Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.Bytes ct)) in
      Alcotest.(check bool) "ciphertext's own hash is unchanged by redaction" true
        (hash_before = hash_after))

let test_redacted_payload_is_genuinely_unrecoverable () =
  (* Review Focus: attempt real decryption after redaction, don't just check the keystore lookup
     returns nothing. *)
  with_store (fun store ->
      let v = Riptide.Value.Scalar (Riptide.Value.String "sensitive") in
      let ct = Redaction_store.encrypt_for_storage store ~event_id:"e1" v in
      Redaction_store.redact store ~event_id:"e1";
      Alcotest.(check bool) "decryption genuinely fails post-redaction" true
        (Redaction_store.decrypt store ~event_id:"e1" ct = None))

(* Per-record granularity (Decision 4): redacting one record must not touch any other. A shared
   or derived DEK would fail this; independently-generated per-record DEKs are exactly what makes
   it hold. *)
let test_redaction_is_per_record () =
  with_store (fun store ->
      let v1 = Riptide.Value.Scalar (Riptide.Value.String "first") in
      let v2 = Riptide.Value.Scalar (Riptide.Value.String "second") in
      let ct1 = Redaction_store.encrypt_for_storage store ~event_id:"e1" v1 in
      let ct2 = Redaction_store.encrypt_for_storage store ~event_id:"e2" v2 in
      Redaction_store.redact store ~event_id:"e1";
      Alcotest.(check bool) "the redacted record is gone" true
        (Redaction_store.decrypt store ~event_id:"e1" ct1 = None);
      Alcotest.(check bool) "its neighbour is untouched" true
        (Redaction_store.decrypt store ~event_id:"e2" ct2 = Some v2))

(* The wrapped DEK is bound to its own event_id as GCM additional authenticated data, so an
   attacker with write access to the keystore cannot swap one record's wrapped DEK onto another
   record's slot and have it silently authenticate.

   This test needs the keystore itself, not just a store handle: the previous version of it merely
   called [decrypt ~event_id:"e2"] on a ciphertext encrypted under "e1", which returns None from
   the keystore MISS alone -- the GCM/AAD path was never reached, and a reviewer confirmed by
   mutation that deleting [~adata] from both Kek.wrap and Kek.unwrap left the whole suite green.
   The real attack is a swap, so the test performs the swap: copy e1's wrapped-DEK blob verbatim
   onto e2's slot, so the lookup genuinely SUCCEEDS and only the AAD binding can reject it. *)
let test_wrapped_dek_is_bound_to_its_event_id () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv =
        Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore"
          dir
      in
      let kek = Kek.of_raw (Mirage_crypto_rng.generate 32) in
      let store = Redaction_store.create ~kv ~kek in
      let v = Riptide.Value.Scalar (Riptide.Value.String "sensitive") in
      let ct = Redaction_store.encrypt_for_storage store ~event_id:"e1" v in
      (* Sanity: the blob really is there, and really does open its own record -- otherwise the
         assertion below could pass for the trivial reason the old test did. *)
      let wrapped_e1 =
        match Riptide_storage.File_kv_store.get kv ~key:"e1" with
        | Some w -> w
        | None -> Alcotest.fail "e1's wrapped DEK should be in the keystore"
      in
      Alcotest.(check bool) "e1 decrypts under its own event_id before the swap" true
        (Redaction_store.decrypt store ~event_id:"e1" ct = Some v);
      (* The attack: the attacker has keystore write access and moves a wrapped DEK to another
         record's slot, hoping it silently authenticates there. *)
      Riptide_storage.File_kv_store.put kv ~key:"e2" wrapped_e1;
      Alcotest.(check bool) "the swapped-in blob is genuinely present at e2 -- the keystore lookup \
                             now SUCCEEDS, so only the AAD binding can reject it"
        true
        (Riptide_storage.File_kv_store.get kv ~key:"e2" = Some wrapped_e1);
      Alcotest.(check bool) "a wrapped DEK moved onto another record's slot fails to unwrap there" true
        (Redaction_store.decrypt store ~event_id:"e2" ct = None);
      (* Pin WHERE that rejection happens: at the KEK unwrap itself, because of the AAD, and not
         at some later ciphertext/decode step that happens to also yield None. Asserted against
         Kek directly, on the very same blob, so dropping [~adata] from Kek.wrap/unwrap fails here
         loudly instead of silently leaving the suite green. *)
      Alcotest.(check bool) "the same blob unwraps under its own AAD" true
        (Kek.unwrap kek ~aad:"e1" wrapped_e1 <> None);
      Alcotest.(check (option string)) "but not under another record's AAD" None
        (Kek.unwrap kek ~aad:"e2" wrapped_e1);
      Alcotest.(check bool) "e1 is untouched by the attack and still opens normally" true
        (Redaction_store.decrypt store ~event_id:"e1" ct = Some v))

let test_decrypt_of_tampered_ciphertext_is_none () =
  with_store (fun store ->
      let v = Riptide.Value.Scalar (Riptide.Value.String "sensitive") in
      let ct = Redaction_store.encrypt_for_storage store ~event_id:"e1" v in
      let tampered = Bytes.of_string ct in
      let last = Bytes.length tampered - 1 in
      Bytes.set tampered last (Char.chr (Char.code (Bytes.get tampered last) lxor 0xff));
      Alcotest.(check bool) "GCM authentication rejects a flipped tag byte" true
        (Redaction_store.decrypt store ~event_id:"e1" (Bytes.to_string tampered) = None))

(* ---- Kek.load: the real, file-based KEK sourcing (Decision 5) ---- *)

let write_key_file ~dir ~name ~perm contents =
  let path = Filename.concat dir name in
  let oc = open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] perm path in
  output_string oc contents;
  close_out oc;
  Unix.chmod path perm;
  path

let test_kek_load_reads_a_well_formed_file () =
  with_tmp_dir (fun dir ->
      let raw = Mirage_crypto_rng.generate 32 in
      let path = write_key_file ~dir ~name:"kek.bin" ~perm:0o600 raw in
      let kek = Kek.load ~path in
      (* Proves the bytes actually loaded are the bytes on disk: a DEK wrapped under the
         file-loaded KEK unwraps under an of_raw KEK built from the same bytes. *)
      let wrapped = Kek.wrap kek ~aad:"e1" "0123456789abcdef0123456789abcdef" in
      Alcotest.(check (option string)) "same key material as the file's own bytes"
        (Some "0123456789abcdef0123456789abcdef")
        (Kek.unwrap (Kek.of_raw raw) ~aad:"e1" wrapped))

let test_kek_load_missing_file_raises () =
  with_tmp_dir (fun dir ->
      let path = Filename.concat dir "absent.bin" in
      Alcotest.(check bool) "a missing KEK file raises rather than defaulting to anything" true
        (try
           ignore (Kek.load ~path);
           false
         with Sys_error _ -> true))

let test_kek_load_wrong_length_raises () =
  with_tmp_dir (fun dir ->
      let short = write_key_file ~dir ~name:"short.bin" ~perm:0o600 (String.make 31 'k') in
      let long = write_key_file ~dir ~name:"long.bin" ~perm:0o600 (String.make 33 'k') in
      let empty = write_key_file ~dir ~name:"empty.bin" ~perm:0o600 "" in
      List.iter
        (fun path ->
          Alcotest.(check bool)
            (Printf.sprintf "a wrong-length KEK file raises (%s)" (Filename.basename path))
            true
            (try
               ignore (Kek.load ~path);
               false
             with Invalid_argument _ -> true))
        [ short; long; empty ])

(* Decision 5 specifies a permissions-restricted file, citing OWASP's Cryptographic Storage Cheat
   Sheet. A KEK readable by group or other is not a KEK; loading one silently would make the whole
   redaction story decorative. *)
let test_kek_load_rejects_a_world_readable_file () =
  with_tmp_dir (fun dir ->
      let path = write_key_file ~dir ~name:"loose.bin" ~perm:0o644 (Mirage_crypto_rng.generate 32) in
      Alcotest.(check bool) "a group/other-readable KEK file is rejected" true
        (try
           ignore (Kek.load ~path);
           false
         with Invalid_argument _ -> true))

(* ---- Kek.wrap/unwrap ---- *)

let test_kek_wrap_unwrap_roundtrip () =
  let kek = Kek.of_raw (Mirage_crypto_rng.generate 32) in
  let dek_raw = Mirage_crypto_rng.generate 32 in
  Alcotest.(check (option string)) "unwraps to the original DEK bytes" (Some dek_raw)
    (Kek.unwrap kek ~aad:"e1" (Kek.wrap kek ~aad:"e1" dek_raw))

let test_kek_unwrap_under_a_different_kek_fails () =
  let kek1 = Kek.of_raw (Mirage_crypto_rng.generate 32) in
  let kek2 = Kek.of_raw (Mirage_crypto_rng.generate 32) in
  let dek_raw = Mirage_crypto_rng.generate 32 in
  Alcotest.(check (option string)) "a different KEK cannot unwrap" None
    (Kek.unwrap kek2 ~aad:"e1" (Kek.wrap kek1 ~aad:"e1" dek_raw))

(* The nonce-reuse regression this module's whole wrapping design exists to avoid: wrapping is a
   one-key-many-messages operation, so it uses a freshly generated 96-bit nonce per wrap (NIST SP
   800-38D §8.2.2's RBG-based construction), NOT a Dek.of_raw reconstruction whose counter resets
   to zero on every call (see kek.mli and lib/crypto/dek.mli's own "Concern for Task 6"). If it
   ever regressed to the latter, every wrap under one KEK would use nonce [prefix || 0] with only
   32 bits of prefix entropy -- which this test would catch as duplicate nonces long before the
   ~2^16 birthday bound, and certainly as a collapsed nonce-entropy distribution. *)
let test_kek_wrap_never_repeats_a_nonce () =
  let kek = Kek.of_raw (Mirage_crypto_rng.generate 32) in
  let dek_raw = Mirage_crypto_rng.generate 32 in
  let n = 10_000 in
  let nonces = List.init n (fun _ -> String.sub (Kek.wrap kek ~aad:"e1" dek_raw) 0 12) in
  Alcotest.(check int) "every wrap used a distinct 12-byte nonce" n
    (List.length (List.sort_uniq compare nonces));
  (* And the entropy really is spread over the whole 96-bit nonce, not over a 32-bit prefix with
     a fixed zero counter -- the exact shape a Dek.of_raw-based wrap would produce. *)
  let trailing_counters = List.sort_uniq compare (List.map (fun nonce -> String.sub nonce 4 8) nonces) in
  Alcotest.(check bool) "the nonce's trailing 8 bytes are not a constant (i.e. not a reset counter)"
    true
    (List.length trailing_counters > 1)

(* ---- the real integration: Batch_commit's own content-hashed write path ---- *)

let fake_event_id name = Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String name))

let create_solo () =
  Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1 ~replica_count:1 ~svc_limit:3
    ~send:(fun ~to_:_ (_ : string) -> ())

let sink_of store : Batch_commit.encryption_sink =
  { encrypt = (fun ~event_id v -> Redaction_store.encrypt_value store ~event_id v) }

let secret = Riptide.Value.Record [ ("ssn", Riptide.Value.Scalar (Riptide.Value.String "123-45-6789")) ]

let write_of payload : Batch_commit.write =
  {
    actor = "actor-1";
    causation = fake_event_id "c1";
    correlation = fake_event_id "r1";
    payload;
    merge_key = None;
  }

(* The central end-to-end proof, and the reason this task touches batch_commit.ml at all:
   encryption happens strictly BEFORE the payload enters the replicated log, which is the only
   place where anything the envelope's content_hash covers is ever decided (lib/batch_commit/
   batch_commit.ml's committed_envelopes is a pure re-derivation from already-committed bytes).
   So the committed envelope's payload IS ciphertext, its content_hash covers ciphertext, and
   redaction leaves that hash -- and the whole chain -- bit-identical. *)
let test_committed_envelope_hashes_ciphertext_and_survives_redaction () =
  with_store (fun store ->
      let replica = create_solo () in
      Batch_commit.propose replica ~idempotency_key:"k1" ~encryption:(sink_of store)
        [ write_of secret ];
      let keyed = Batch_commit.committed_envelopes_keyed replica in
      Alcotest.(check int) "one committed envelope" 1 (List.length keyed);
      let event_id, envelope = List.hd keyed in

      (* (a) The committed envelope's payload is ciphertext, not the plaintext value. *)
      Alcotest.(check bool) "the committed payload is not the plaintext value" false
        (envelope.Riptide.Envelope.payload = secret);
      Alcotest.(check bool) "the committed payload's bytes do not contain the secret" false
        (try
           ignore
             (Str.search_forward (Str.regexp_string "123-45-6789")
                (Riptide.Value.canonical_encode envelope.Riptide.Envelope.payload)
                0);
           true
         with Not_found -> false);

      (* (b) It decrypts back, through the keystore, under the event_id the write path assigned. *)
      Alcotest.(check bool) "decrypts back to the original plaintext value" true
        (Redaction_store.decrypt_value store ~event_id envelope.Riptide.Envelope.payload = Some secret);

      (* (c) content_hash covers that ciphertext, the chain verifies, and redaction changes
         NEITHER -- the envelope is never touched, read, or recomputed by a redaction. *)
      let hash_before = Riptide.Envelope.content_hash envelope in
      Alcotest.(check bool) "the chain verifies before redaction" true
        (Riptide.Log.verify_chain_list (Batch_commit.committed_envelopes replica));
      Redaction_store.redact store ~event_id;
      let envelope_after = List.hd (Batch_commit.committed_envelopes replica) in
      Alcotest.(check bool) "the envelope's content_hash is bit-identical after redaction" true
        (Riptide.Envelope.content_hash envelope_after = hash_before);
      Alcotest.(check bool) "the chain still verifies after redaction" true
        (Riptide.Log.verify_chain_list (Batch_commit.committed_envelopes replica));

      (* (d) And the payload is genuinely unrecoverable -- attempted decryption, not merely a
         missing keystore row. *)
      Alcotest.(check bool) "the payload is genuinely unrecoverable after redaction" true
        (Redaction_store.decrypt_value store ~event_id envelope_after.Riptide.Envelope.payload = None))

(* Each write in a batch gets its own event_id, hence its own independently-redactable DEK. *)
let test_each_write_in_a_batch_is_independently_redactable () =
  with_store (fun store ->
      let replica = create_solo () in
      let v i = Riptide.Value.Scalar (Riptide.Value.String (Printf.sprintf "secret-%d" i)) in
      Batch_commit.propose replica ~idempotency_key:"k1" ~encryption:(sink_of store)
        [ write_of (v 0); write_of (v 1); write_of (v 2) ];
      let keyed = Batch_commit.committed_envelopes_keyed replica in
      Alcotest.(check int) "three committed envelopes" 3 (List.length keyed);
      Alcotest.(check int) "three distinct event_ids" 3
        (List.length (List.sort_uniq compare (List.map fst keyed)));
      let event_id1, envelope1 = List.nth keyed 1 in
      Redaction_store.redact store ~event_id:event_id1;
      List.iteri
        (fun i (event_id, (e : Riptide.Envelope.envelope)) ->
          let expected = if i = 1 then None else Some (v i) in
          Alcotest.(check bool)
            (Printf.sprintf "write %d recoverable = %b" i (i <> 1))
            true
            (Redaction_store.decrypt_value store ~event_id e.payload = expected))
        keyed;
      ignore envelope1)

(* A retry of an already-committed idempotency_key must NOT re-encrypt: doing so would mint a
   fresh DEK and overwrite the keystore entry for a ciphertext already immutably in the log,
   permanently destroying a record nobody asked to redact. *)
let test_retrying_an_already_committed_batch_does_not_orphan_its_dek () =
  with_store (fun store ->
      let replica = create_solo () in
      Batch_commit.propose replica ~idempotency_key:"k1" ~encryption:(sink_of store)
        [ write_of secret ];
      let event_id, envelope = List.hd (Batch_commit.committed_envelopes_keyed replica) in
      Batch_commit.propose replica ~idempotency_key:"k1" ~encryption:(sink_of store)
        [ write_of secret ];
      Alcotest.(check int) "the retry added no second envelope" 1
        (List.length (Batch_commit.committed_envelopes replica));
      Alcotest.(check bool) "the committed ciphertext still decrypts after the retry" true
        (Redaction_store.decrypt_value store ~event_id envelope.Riptide.Envelope.payload = Some secret))

(* ---- the propose-but-not-yet-committed window, over a real multi-replica cluster ----

   Every encryption test above runs against [create_solo ()] (replica_count = 1), where
   Replica.propose commits SYNCHRONOUSLY -- so the window this section is about does not exist
   there at all, which is exactly why the bug it pins was missed in the first round.

   Why this harness and not test_batch_commit_cluster.ml's own [with_cluster]: that one (like
   Riptide_dst.Cluster.run) drives its replicas' dispatch fibers under [Eio_mock.Backend.run],
   which provides no real filesystem -- and [Riptide_storage.File_kv_store] (the keystore every
   encryption test needs) is built on [Eio_linux.Low_level]/io_uring and therefore needs
   [Eio_main.run]'s real backend. The two cannot nest. So the cluster below keeps the parts that
   matter for THIS bug -- three real Replica.t instances at replica_count = 3, real encoded
   Prepare/PrepareOk bytes, a real f + 1 = 2 quorum, commit strictly asynchronous -- and replaces
   only the fiber-based transport with a synchronous in-process queue drained by [deliver_all].
   Nothing is hand-forged: every message delivered is bytes a real replica actually sent. This
   matches test_vsr_replica.ml's own established "drive handle_message directly" convention,
   applied to messages the cluster generated itself. *)
let with_store_and_cluster ~replica_count f =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv =
        Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore"
          dir
      in
      let store = Redaction_store.create ~kv ~kek:(Kek.of_raw (Mirage_crypto_rng.generate 32)) in
      let inflight : (int * string) Queue.t = Queue.create () in
      let replicas =
        Array.init replica_count (fun i ->
            Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:(i + 1) ~replica_count
              ~svc_limit:3 ~send:(fun ~to_ bytes -> Queue.add (to_, bytes) inflight))
      in
      (* Same reason every cluster harness in this repo does this (see test_batch_commit_cluster.ml
         and Riptide_dst.Cluster): a fresh replica starts at view 0, where Primary(0) =
         replica_count, so replicas.(0) would NOT be the primary and every propose against it
         would be a silent no-op. Primary(1) = 1 for any replica_count. All replicas must be
         pinned to the same view or they reject each other's messages outright. *)
      Array.iter (fun r -> Replica.for_test_set_view_number r 1) replicas;
      let deliver_all () =
        while not (Queue.is_empty inflight) do
          let to_, bytes = Queue.pop inflight in
          Replica.handle_message replicas.(to_ - 1) bytes
        done
      in
      f ~store ~replicas ~deliver_all)

(* THE regression test for the review's Critical finding (2026-09-23). A client retry issued in
   the propose-but-not-yet-committed window is not a fault: this layer has no acknowledgment
   mechanism at all (batch_commit.mli's propose is explicitly fire-and-forget), so it is the only
   kind of retry a client can issue, and in a replica_count >= 3 cluster that window is the normal
   state of every proposal.

   Pre-fix, [Batch_commit.propose] gated encryption on [already_committed] (the committed prefix
   only), so the retry re-encrypted: a fresh DEK overwrote the first one in the keystore under the
   same derived event_id, and because the fresh nonce made the batch bytes DIFFERENT,
   Replica.propose's own byte-identical-value suppression did not catch it and a second entry was
   appended. Both entries commit; committed_envelopes_keyed keeps the first; its ciphertext is
   unopenable by the only surviving DEK. Silent, permanent loss, no fault injected, hash chain
   still verifying. *)
let test_retrying_an_uncommitted_batch_in_a_cluster_keeps_it_decryptable () =
  with_store_and_cluster ~replica_count:3 (fun ~store ~replicas ~deliver_all ->
      let primary = replicas.(0) in
      Batch_commit.propose primary ~idempotency_key:"k1" ~encryption:(sink_of store) [ write_of secret ];
      (* The window itself, asserted rather than assumed -- if commit were synchronous here (as it
         is for replica_count = 1) this test would be testing nothing. *)
      Alcotest.(check int) "the batch is in the primary's own log" 1 (List.length (Replica.entries primary));
      Alcotest.(check int) "but nothing has committed yet -- this is the window under test" 0
        (Replica.commit_number primary);
      (* The retry, inside that window, with the same key and the same writes. *)
      Batch_commit.propose primary ~idempotency_key:"k1" ~encryption:(sink_of store) [ write_of secret ];
      Alcotest.(check int)
        "the retry appended NO second entry -- it must not re-encrypt to different bytes and slip \
         past Replica.propose's own identical-value suppression"
        1
        (List.length (Replica.entries primary));
      (* Now let the cluster actually reach quorum and commit, the ordinary asynchronous way. *)
      deliver_all ();
      Alcotest.(check int) "the batch committed via a real f + 1 = 2 PrepareOk quorum" 1
        (Replica.commit_number primary);
      let keyed = Batch_commit.committed_envelopes_keyed primary in
      Alcotest.(check int) "exactly one committed envelope" 1 (List.length keyed);
      let event_id, envelope = List.hd keyed in
      (* The whole point: the record that actually committed is still readable. Pre-fix this is
         None -- the keystore holds the retry's DEK, the log holds the first attempt's
         ciphertext. *)
      Alcotest.(check bool)
        "the committed record is still decryptable after a retry in the uncommitted window" true
        (Redaction_store.decrypt_value store ~event_id envelope.Riptide.Envelope.payload = Some secret);
      Alcotest.(check bool) "and the chain verifies" true
        (Riptide.Log.verify_chain_list (Batch_commit.committed_envelopes primary)))

(* The same window, but for the property the fix must NOT break: an unencrypted retry of an
   identical batch was always a safe no-op via Replica.propose's own value_equal suppression, and
   still is. Guards against "fixed the encrypted case by changing the underlying suppression". *)
let test_unencrypted_retry_in_the_uncommitted_window_is_still_a_no_op () =
  with_store_and_cluster ~replica_count:3 (fun ~store:_ ~replicas ~deliver_all ->
      let primary = replicas.(0) in
      Batch_commit.propose primary ~idempotency_key:"k1" [ write_of secret ];
      Alcotest.(check int) "appended, not committed" 0 (Replica.commit_number primary);
      Batch_commit.propose primary ~idempotency_key:"k1" [ write_of secret ];
      Alcotest.(check int) "the unencrypted retry appended no second entry either" 1
        (List.length (Replica.entries primary));
      deliver_all ();
      let envelopes = Batch_commit.committed_envelopes primary in
      Alcotest.(check int) "one committed envelope" 1 (List.length envelopes);
      Alcotest.(check bool) "payload is the plaintext value, untouched" true
        ((List.hd envelopes).Riptide.Envelope.payload = secret))

(* Encrypted payloads and materialization are, today, mutually exclusive: the materializer's
   accumulator holds joined PLAINTEXT derived from the payload and lives entirely outside the
   keystore, so deleting a DEK would not erase the record's contribution to it -- a redaction that
   silently does not redact. Batch_commit rejects the combination loudly rather than shipping that
   hole. See batch_commit.mli's own doc comment and this task's report (Concerns). *)
let test_encryption_with_merge_key_is_rejected () =
  with_store (fun store ->
      let replica = create_solo () in
      let w = { (write_of secret) with Batch_commit.merge_key = Some "mk" } in
      Alcotest.check_raises "encrypted + materialized is rejected"
        (Invalid_argument
           "Batch_commit.propose: a write with merge_key = Some _ cannot also be encrypted \
            (~encryption): the materialized accumulator is outside the redaction keystore, so \
            deleting the DEK would not erase it")
        (fun () -> Batch_commit.propose replica ~idempotency_key:"k1" ~encryption:(sink_of store) [ w ]);
      Alcotest.(check int) "nothing was committed" 0
        (List.length (Batch_commit.committed_envelopes replica)))

(* Without ~encryption, nothing changes for any existing caller: payloads stay plaintext and the
   derived event_ids are still available for callers that key anything else off them. *)
let test_without_encryption_payloads_are_unchanged () =
  let replica = create_solo () in
  Batch_commit.propose replica ~idempotency_key:"k1" [ write_of secret ];
  let envelopes = Batch_commit.committed_envelopes replica in
  Alcotest.(check int) "one committed envelope" 1 (List.length envelopes);
  Alcotest.(check bool) "payload is the plaintext value, untouched" true
    ((List.hd envelopes).Riptide.Envelope.payload = secret)

let tests =
  [
    ("encrypt then decrypt", `Quick, test_encrypt_then_decrypt);
    ("ciphertext does not contain the plaintext", `Quick, test_ciphertext_does_not_contain_the_plaintext);
    ( "content_hash of ciphertext is stable across redaction",
      `Quick,
      test_content_hash_of_ciphertext_is_stable_across_redaction );
    ("redacted payload is genuinely unrecoverable", `Quick, test_redacted_payload_is_genuinely_unrecoverable);
    ("redaction is per record", `Quick, test_redaction_is_per_record);
    ("wrapped DEK is bound to its event_id", `Quick, test_wrapped_dek_is_bound_to_its_event_id);
    ("decrypt of tampered ciphertext is None", `Quick, test_decrypt_of_tampered_ciphertext_is_none);
    ("Kek.load reads a well-formed file", `Quick, test_kek_load_reads_a_well_formed_file);
    ("Kek.load on a missing file raises", `Quick, test_kek_load_missing_file_raises);
    ("Kek.load on a wrong-length file raises", `Quick, test_kek_load_wrong_length_raises);
    ("Kek.load rejects a world-readable file", `Quick, test_kek_load_rejects_a_world_readable_file);
    ("Kek.wrap/unwrap round-trip", `Quick, test_kek_wrap_unwrap_roundtrip);
    ("Kek.unwrap under a different KEK fails", `Quick, test_kek_unwrap_under_a_different_kek_fails);
    ("Kek.wrap never repeats a nonce", `Quick, test_kek_wrap_never_repeats_a_nonce);
    ( "committed envelope hashes ciphertext and survives redaction",
      `Quick,
      test_committed_envelope_hashes_ciphertext_and_survives_redaction );
    ( "each write in a batch is independently redactable",
      `Quick,
      test_each_write_in_a_batch_is_independently_redactable );
    ( "retrying an already-committed batch does not orphan its DEK",
      `Quick,
      test_retrying_an_already_committed_batch_does_not_orphan_its_dek );
    ( "a retry in the propose-but-uncommitted window keeps the committed record decryptable \
       (3-replica cluster)",
      `Quick,
      test_retrying_an_uncommitted_batch_in_a_cluster_keeps_it_decryptable );
    ( "an unencrypted retry in that same window is still a no-op",
      `Quick,
      test_unencrypted_retry_in_the_uncommitted_window_is_still_a_no_op );
    ("encryption with merge_key is rejected", `Quick, test_encryption_with_merge_key_is_rejected);
    ("without encryption payloads are unchanged", `Quick, test_without_encryption_payloads_are_unchanged);
  ]
