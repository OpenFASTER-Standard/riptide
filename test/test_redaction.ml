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
        Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:Redaction_store.owner_tag
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

(* Task 24: the raw KV value is no longer just Kek.wrap's own output -- it is now
   Redaction_store.encode_record's [event_id]-prefixed record ([lib/crypto/redaction_store.ml]:
   "<len>:<event_id><wrapped>"). [encode_record]/[decode_record] are private to that module, so
   this mirrors their exact format by hand, the same way this test file already duplicates other
   modules' private on-disk layout details for a deeper assertion than their public interface alone
   would allow (see [test_file_kv_store.ml]'s own [owner_marker_name]/[key_hash_hex] literals for
   the established precedent). This lets the assertions below reach the true wrapped-DEK bytes
   directly, so they still pin WHERE the swap is rejected (at Kek.unwrap itself, via the AAD) rather
   than at the record's own outer encoding. *)
let strip_embedded_event_id_prefix record =
  match String.index_opt record ':' with
  | None -> Alcotest.fail "record does not start with a length-prefixed event_id"
  | Some colon_idx ->
    let len = int_of_string (String.sub record 0 colon_idx) in
    String.sub record (colon_idx + 1 + len) (String.length record - colon_idx - 1 - len)

let test_wrapped_dek_is_bound_to_its_event_id () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv =
        Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:Redaction_store.owner_tag
          dir
      in
      let kek = Kek.of_raw (Mirage_crypto_rng.generate 32) in
      let store = Redaction_store.create ~kv ~kek in
      let v = Riptide.Value.Scalar (Riptide.Value.String "sensitive") in
      let ct = Redaction_store.encrypt_for_storage store ~event_id:"e1" v in
      (* Sanity: the blob really is there, and really does open its own record -- otherwise the
         assertion below could pass for the trivial reason the old test did. *)
      let record_e1 =
        match Riptide_storage.File_kv_store.get kv ~key:"e1" with
        | Some w -> w
        | None -> Alcotest.fail "e1's wrapped DEK should be in the keystore"
      in
      let wrapped_e1 = strip_embedded_event_id_prefix record_e1 in
      Alcotest.(check bool) "e1 decrypts under its own event_id before the swap" true
        (Redaction_store.decrypt store ~event_id:"e1" ct = Some v);
      (* The attack: the attacker has keystore write access and moves a wrapped DEK record to
         another record's slot, hoping it silently authenticates there. The whole record moves
         (embedded event_id prefix and all) -- exactly what a real attacker with only keystore
         write access, not this module's own source, can do. *)
      Riptide_storage.File_kv_store.put kv ~key:"e2" record_e1;
      Alcotest.(check bool) "the swapped-in record is genuinely present at e2 -- the keystore lookup \
                             now SUCCEEDS, so only the AAD binding can reject it"
        true
        (Riptide_storage.File_kv_store.get kv ~key:"e2" = Some record_e1);
      Alcotest.(check bool) "a wrapped DEK moved onto another record's slot fails to unwrap there" true
        (Redaction_store.decrypt store ~event_id:"e2" ct = None);
      (* Pin WHERE that rejection happens: at the KEK unwrap itself, because of the AAD, and not
         at some later ciphertext/decode step that happens to also yield None. Asserted against
         Kek directly, on the true wrapped-DEK bytes (the embedded event_id prefix stripped off),
         so dropping [~adata] from Kek.wrap/unwrap fails here loudly instead of silently leaving the
         suite green -- see [unwrap_dek_with]'s own comment in redaction_store.ml (Task 25: the
         function this logic now lives in) for why Redaction_store itself deliberately never gates
         on the embedded event_id the way this direct Kek-level
         assertion is free to, for a plain diagnostic purpose, here in the test alone. *)
      Alcotest.(check bool) "the same blob unwraps under its own AAD" true
        (Kek.unwrap kek ~aad:"e1" wrapped_e1 <> None);
      Alcotest.(check (option string)) "but not under another record's AAD" None
        (Kek.unwrap kek ~aad:"e2" wrapped_e1);
      Alcotest.(check bool) "e1 is untouched by the attack and still opens normally" true
        (Redaction_store.decrypt store ~event_id:"e1" ct = Some v))

(* -- Task 24: Redaction_store.enumerate_event_ids. The plan's own sketch test used a
   [Redaction_store.wrap] function that does not exist on this module's real surface -- the real
   write path is [encrypt_for_storage] -- and asserted recoverability "via enumeration alone",
   which is the property actually worth pinning: before this task, the KV store's own keys are
   hashed away before they ever touch disk (see [kv_store_intf.ml]'s [fold] doc and
   [file_kv_store.ml]'s [path_for]), so nothing short of an external log of every [event_id] ever
   written could recover this set. This test proves that log is no longer needed. *)
let test_enumerate_event_ids_recovers_every_event_id_with_no_external_log () =
  with_store (fun store ->
      let v i = Riptide.Value.Scalar (Riptide.Value.String (Printf.sprintf "secret-%d" i)) in
      ignore (Redaction_store.encrypt_for_storage store ~event_id:"evt-1" (v 1));
      ignore (Redaction_store.encrypt_for_storage store ~event_id:"evt-2" (v 2));
      ignore (Redaction_store.encrypt_for_storage store ~event_id:"evt-3" (v 3));
      let found = List.sort compare (Redaction_store.enumerate_event_ids store) in
      Alcotest.(check (list string))
        "every event_id that was ever encrypt_for_storage'd is recoverable via enumeration alone, \
         with no external log ever consulted"
        [ "evt-1"; "evt-2"; "evt-3" ] found)

(* Review finding (Important, first round): [enumerate_event_ids]'s two [None -> acc] silent-skip
   branches (decode failure on a record read back successfully; [get_by_hash] itself returning
   [None] for a hash [fold] just yielded) were previously prose-justified only, with no test
   exercising either. This closes that: plants a GARBAGE value directly via
   [File_kv_store.put], bypassing [Redaction_store] entirely (simulating either a foreign write
   into this keystore's directory, or a future format drift this module's own encode/decode pair
   didn't anticipate), alongside one real [encrypt_for_storage]'d entry. "not-a-valid-record"
   contains no [':'], so [decode_record] hits its very first [None] case
   ([String.index_opt raw ':' = None]) -- this is a REAL, checksummed [File_kv_store] record (so
   [get_by_hash] returns [Some "not-a-valid-record"]), which is exactly what makes it a decode
   failure specifically, not a [get_by_hash]-returns-[None] case (covered separately below). *)
let test_enumerate_event_ids_skips_an_undecodable_record_without_raising () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv =
        Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:Redaction_store.owner_tag
          dir
      in
      let kek = Kek.of_raw (Mirage_crypto_rng.generate 32) in
      let store = Redaction_store.create ~kv ~kek in
      ignore
        (Redaction_store.encrypt_for_storage store ~event_id:"valid-event"
           (Riptide.Value.Scalar (Riptide.Value.String "sensitive")));
      (* A real, durably-stored, correctly-checksummed [File_kv_store] record whose VALUE is not
         shaped like [encode_record]'s output at all -- [Redaction_store] itself never wrote this;
         nothing about [File_kv_store]'s own contract prevents another writer (or a bug) from
         doing so. *)
      Riptide_storage.File_kv_store.put kv ~key:"garbage" "not-a-valid-record";
      let found = Redaction_store.enumerate_event_ids store in
      Alcotest.(check (list string))
        "the undecodable record is silently skipped -- only the real event_id is recovered, and \
         nothing raised"
        [ "valid-event" ] found)

(* Same finding, the OTHER silent-skip branch: [get_by_hash] itself returning [None] for a hash
   [fold] legitimately yielded. The doc's own account of this (redaction_store.ml,
   [enumerate_event_ids]'s comment) is "the record was deleted between fold's directory listing and
   this read, or it failed its own checksum" -- the checksum-failure half of that is reproducible
   deterministically, with no concurrency required: write a syntactically-real key file (64
   lowercase hex characters, so [fold]'s own [is_real_key_filename] check accepts it and visits it)
   directly at its own computed sharded path, containing bytes that are not a valid
   [header_slot_size]-then-[data_slot_size] record at all -- so [File_kv_store.get_by_hash]'s own
   checksum verification genuinely fails and returns [None], independent of and prior to
   [Redaction_store]'s own [decode_record] ever running on it. This is the SAME underlying
   [Kv_store_intf.S.get]-style "cannot distinguish never-written from corrupted" ambiguity as the
   deleted-mid-fold race the doc comment also describes -- not independently distinguishable from
   it in a realistic single-threaded test, since both collapse into the exact same [get_by_hash]
   [None] outcome by construction; this test exercises that shared outcome directly rather than via
   a genuine race, since a real race would be inherently flaky to script from a test. *)
let key_hash_hex key =
  Riptide.Value.hash_to_hex
    (Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String key)))

let plant_a_corrupt_leaf_file_at_its_own_sharded_path dir key =
  let hash = key_hash_hex key in
  let shard1 = Filename.concat dir (String.sub hash 0 2) in
  let shard2 = Filename.concat shard1 (String.sub hash 2 2) in
  (try Unix.mkdir shard1 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir shard2 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat shard2 hash in
  let oc = open_out_bin path in
  output_string oc "not a valid header+data record -- too short, wrong checksum, garbage bytes";
  close_out oc

let test_enumerate_event_ids_skips_a_hash_whose_record_fails_durable_read_without_raising () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv =
        Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:Redaction_store.owner_tag
          dir
      in
      let kek = Kek.of_raw (Mirage_crypto_rng.generate 32) in
      let store = Redaction_store.create ~kv ~kek in
      ignore
        (Redaction_store.encrypt_for_storage store ~event_id:"valid-event"
           (Riptide.Value.Scalar (Riptide.Value.String "sensitive")));
      (* A real, [fold]-visitable leaf (a syntactically valid 64-lowercase-hex filename, in its own
         correct shard subdirectory) whose CONTENT is not a valid [File_kv_store] record -- so
         [get_by_hash] returns [None] for this hash even though [fold] visited it. (Re-review
         finding: this planted content is short enough to be rejected already at [durable_read]'s
         header-read stage, before any checksum comparison is reached -- "fails its own checksum"
         overstated the specific mechanism. Either way it is the same documented
         "cannot distinguish never-written from corrupted" contract [get]/[get_by_hash] already
         state, and exercises the same [get_by_hash]-returns-[None] branch this test targets.) *)
      plant_a_corrupt_leaf_file_at_its_own_sharded_path dir "corrupt-key";
      (* Sanity: confirm the premise -- [get_by_hash] genuinely returns [None] for this hash, not
         [Some] something [decode_record] merely happens to reject; otherwise this test would
         exercise the same decode-failure branch the previous test already covers, not this one. *)
      Alcotest.(check (option string)) "the planted leaf's own hash reads back as None (rejected by \
                                        durable_read), not Some"
        None
        (Riptide_storage.File_kv_store.get_by_hash kv ~hash:(key_hash_hex "corrupt-key"));
      let found = Redaction_store.enumerate_event_ids store in
      Alcotest.(check (list string))
        "the unreadable hash is silently skipped -- only the real event_id is recovered, and \
         nothing raised"
        [ "valid-event" ] found)

(* [redact] deletes the KV entry entirely, so enumeration must reflect that too -- a redacted
   event_id must not still show up as if it were live. *)
let test_enumerate_event_ids_does_not_include_a_redacted_event_id () =
  with_store (fun store ->
      let v = Riptide.Value.Scalar (Riptide.Value.String "sensitive") in
      ignore (Redaction_store.encrypt_for_storage store ~event_id:"stays" v);
      ignore (Redaction_store.encrypt_for_storage store ~event_id:"goes" v);
      Redaction_store.redact store ~event_id:"goes";
      let found = List.sort compare (Redaction_store.enumerate_event_ids store) in
      Alcotest.(check (list string)) "only the non-redacted event_id remains enumerable" [ "stays" ]
        found)

(* -- Task 25: Redaction_store.rotate_kek -- the KEK-compromise remediation path. Before this
   task, the only way to recover from a compromised KEK was to destroy every record this keystore
   protects (nothing could re-wrap them under a fresh key); rotate_kek is that recovery path. See
   redaction_store.mli's own [rotate_kek] doc for the full design argument this task's tests below
   pin down: per-entry (not cross-entry) atomicity, the chosen resumability behavior (a second call
   after a partial failure completes the rotation rather than requiring an operator to reconstruct
   progress by hand), and the corrupted-entry judgment (raise loudly, rather than silently skip). *)

let with_two_kek_store f =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv =
        Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:Redaction_store.owner_tag
          dir
      in
      let kek1 = Kek.of_raw (Mirage_crypto_rng.generate 32) in
      let kek2 = Kek.of_raw (Mirage_crypto_rng.generate 32) in
      let store = Redaction_store.create ~kv ~kek:kek1 in
      f ~kv ~kek1 ~kek2 ~store)

let value_for id = Riptide.Value.Scalar (Riptide.Value.String ("secret-" ^ id))

(* Reconstructs [Redaction_store.encode_record]'s own private, length-prefixed format by hand --
   the exact same duplication this file's own [strip_embedded_event_id_prefix] (above) already
   relies on for [test_wrapped_dek_is_bound_to_its_event_id], for the same reason: reaching the
   true on-disk record shape for a deeper assertion/simulation than the public interface alone
   would allow. *)
let build_record ~event_id wrapped = Printf.sprintf "%d:%s%s" (String.length event_id) event_id wrapped

(* Simulates a real process crash partway through {!Redaction_store.rotate_kek}: performs exactly
   the same primitives rotate_kek's own per-entry step does (read the record, unwrap under the old
   kek, re-wrap the SAME dek bytes under the new kek, write the record back) directly against
   [kv], for one chosen [event_id], without ever calling [rotate_kek] itself.

   This is a deliberate stand-in for a genuine crash, not a contrived shortcut: each entry's own
   rewrite depends on nothing but its own [event_id] (no shared state or ordering with any other
   entry), so the on-disk result of doing this for N of M entries is bit-identical to whatever a
   real crash after exactly N successful iterations of rotate_kek's own loop would leave. Scripting
   an actual crash mid-loop would instead depend on controlling
   {!Riptide_storage.File_kv_store.fold}'s own enumeration order to decide which N entries "got
   there first" -- but that order is explicitly unspecified (see [file_kv_store.ml]'s own [fold]
   comment and [kv_store_intf.mli]'s), so a test relying on it would be flaky by construction. This
   file already makes the identical deliberate choice for the same reason in
   [plant_a_corrupt_leaf_file_at_its_own_sharded_path] above (see that function's own comment). *)
let simulate_one_rotation_step ~kv ~old_kek ~new_kek event_id =
  match Riptide_storage.File_kv_store.get kv ~key:event_id with
  | None -> Alcotest.fail (Printf.sprintf "expected %s to already be stored" event_id)
  | Some record -> (
    let wrapped = strip_embedded_event_id_prefix record in
    match Kek.unwrap old_kek ~aad:event_id wrapped with
    | None -> Alcotest.fail (Printf.sprintf "expected %s to still be wrapped under old_kek" event_id)
    | Some dek_raw ->
      let new_wrapped = Kek.wrap new_kek ~aad:event_id dek_raw in
      Riptide_storage.File_kv_store.put kv ~key:event_id (build_record ~event_id new_wrapped))

let test_rotate_kek_re_wraps_every_entry_and_old_kek_no_longer_decrypts () =
  with_two_kek_store (fun ~kv:_ ~kek1 ~kek2 ~store ->
      let ids = [ "e1"; "e2"; "e3" ] in
      let cts =
        List.map (fun id -> (id, Redaction_store.encrypt_for_storage store ~event_id:id (value_for id))) ids
      in
      Redaction_store.rotate_kek store ~new_kek:kek2;
      List.iter
        (fun (id, ct) ->
          Alcotest.(check bool) (Printf.sprintf "%s decrypts under the new KEK after rotation" id) true
            (Redaction_store.decrypt_with store ~kek:kek2 ~event_id:id ct = Some (value_for id));
          Alcotest.(check bool) (Printf.sprintf "%s no longer decrypts under the old KEK" id) true
            (Redaction_store.decrypt_with store ~kek:kek1 ~event_id:id ct = None))
        cts;
      (* rotate_kek also switches [store]'s own key in place, so ordinary [decrypt] (which always
         uses [t.kek], never an explicit key) now works with no override at all. *)
      List.iter
        (fun (id, ct) ->
          Alcotest.(check bool) (Printf.sprintf "%s: ordinary decrypt now uses the new key too" id) true
            (Redaction_store.decrypt store ~event_id:id ct = Some (value_for id)))
        cts)

let test_rotate_kek_interrupted_partway_leaves_a_readable_mix_not_torn_entries () =
  with_two_kek_store (fun ~kv ~kek1 ~kek2 ~store ->
      let ids = [ "e1"; "e2"; "e3" ] in
      let cts =
        List.map (fun id -> (id, Redaction_store.encrypt_for_storage store ~event_id:id (value_for id))) ids
      in
      (* Simulate a crash after 2 of the 3 entries have rotated; "e3" is deliberately left
         untouched, still wrapped under kek1. *)
      simulate_one_rotation_step ~kv ~old_kek:kek1 ~new_kek:kek2 "e1";
      simulate_one_rotation_step ~kv ~old_kek:kek1 ~new_kek:kek2 "e2";
      List.iter
        (fun (id, ct) ->
          let under_old = Redaction_store.decrypt_with store ~kek:kek1 ~event_id:id ct in
          let under_new = Redaction_store.decrypt_with store ~kek:kek2 ~event_id:id ct in
          Alcotest.(check bool)
            (Printf.sprintf "%s decrypts under exactly one of the two keys, never both and never \
                              neither -- i.e. it is not torn" id)
            true
            ((under_old = Some (value_for id)) <> (under_new = Some (value_for id)));
          match id with
          | "e1" | "e2" ->
            Alcotest.(check bool) (Printf.sprintf "%s has already rotated to the new key" id) true
              (under_new = Some (value_for id))
          | _ ->
            Alcotest.(check bool) (Printf.sprintf "%s has not yet rotated -- still under the old key" id)
              true
              (under_old = Some (value_for id)))
        cts)

let test_rotate_kek_second_call_after_a_partial_failure_is_resumable () =
  with_two_kek_store (fun ~kv ~kek1 ~kek2 ~store ->
      let ids = [ "e1"; "e2"; "e3" ] in
      let cts =
        List.map (fun id -> (id, Redaction_store.encrypt_for_storage store ~event_id:id (value_for id))) ids
      in
      (* Simulate: a first rotate_kek call was interrupted after 2 of 3 entries -- see
         [simulate_one_rotation_step]'s own comment for why this stands in for a genuine crash.
         [store]'s own kek is still kek1, exactly as a real interrupted rotate_kek would leave it,
         since the (simulated) first attempt never reached its own final assignment. *)
      simulate_one_rotation_step ~kv ~old_kek:kek1 ~new_kek:kek2 "e1";
      simulate_one_rotation_step ~kv ~old_kek:kek1 ~new_kek:kek2 "e2";
      (* The resumed, real call: must complete cleanly even though "e1"/"e2" are already under
         kek2 while [store] itself still believes its key is kek1. *)
      Redaction_store.rotate_kek store ~new_kek:kek2;
      List.iter
        (fun (id, ct) ->
          Alcotest.(check bool)
            (Printf.sprintf "%s decrypts via ordinary decrypt once the resumed rotation completes" id)
            true
            (Redaction_store.decrypt store ~event_id:id ct = Some (value_for id));
          Alcotest.(check bool) (Printf.sprintf "%s no longer opens under the old KEK" id) true
            (Redaction_store.decrypt_with store ~kek:kek1 ~event_id:id ct = None))
        cts)

(* Task 25 re-review (Important): the resumability fallback ("try this call's old_kek, then this
   call's new_kek") has a real, documented precondition -- a resumed call MUST pass the SAME
   ~new_kek the abandoned attempt used. This pins the false-positive that follows if it doesn't:
   an entry already rotated to kek2 by an interrupted first attempt is wrapped under NEITHER of a
   second call's two candidates (kek1, the still-current t.kek, and kek3, a genuinely different
   replacement key) -- so it raises Undecryptable_entry even though it is perfectly intact and
   trivially recoverable by retrying with kek2. redaction_store.mli's own [rotate_kek] doc
   documents exactly this as the "REAL PRECONDITION" disclosure; this test proves the documented
   behavior is what the code actually does, not merely what the prose claims. *)
let test_rotate_kek_resumed_with_a_different_new_kek_than_the_abandoned_attempt_raises () =
  with_two_kek_store (fun ~kv ~kek1 ~kek2 ~store ->
      let kek3 = Kek.of_raw (Mirage_crypto_rng.generate 32) in
      let ids = [ "e1"; "e2"; "e3" ] in
      let cts =
        List.map (fun id -> (id, Redaction_store.encrypt_for_storage store ~event_id:id (value_for id))) ids
      in
      (* First attempt, interrupted after 2 of 3 entries rotated to kek2 -- [store]'s own kek is
         still kek1, exactly as a real interrupted rotate_kek would leave it. Both "e1" and "e2"
         are now wrapped under kek2 and are the ones the resumed call below will misdiagnose;
         "e3" is left genuinely under kek1 and would rotate cleanly if reached first (harmless --
         not what this test is pinning down). *)
      simulate_one_rotation_step ~kv ~old_kek:kek1 ~new_kek:kek2 "e1";
      simulate_one_rotation_step ~kv ~old_kek:kek1 ~new_kek:kek2 "e2";
      (* The resuming call uses kek3, NOT kek2 -- the precondition violation under test. Which of
         "e1"/"e2" is reported is NOT asserted: {!Riptide_storage.File_kv_store.fold}'s own
         enumeration order is explicitly unspecified (see [enumerate_event_ids]'s own uses of it
         elsewhere in this file), so either could be visited, and raise, first. *)
      let raised_event_id =
        match Redaction_store.rotate_kek store ~new_kek:kek3 with
        | () ->
          Alcotest.fail
            "expected rotate_kek to raise Undecryptable_entry when resumed with a DIFFERENT \
             ~new_kek than the abandoned attempt used"
        | exception Redaction_store.Undecryptable_entry event_id -> event_id
      in
      Alcotest.(check bool)
        "the exception names one of the two already-rotated (misdiagnosed, but perfectly intact) \
         entries, not e3 (which was never touched by the first attempt)"
        true
        (raised_event_id = "e1" || raised_event_id = "e2");
      (* Both misdiagnosed entries are proven intact: they still open cleanly under kek2, the key
         the (simulated) first attempt actually used -- neither corrupted nor lost, just wrapped
         under a key this second call never tried. *)
      List.iter
        (fun id ->
          let _, ct = List.find (fun (id', _) -> id' = id) cts in
          Alcotest.(check bool) (Printf.sprintf "%s is genuinely intact under kek2, not corrupted" id)
            true
            (Redaction_store.decrypt_with store ~kek:kek2 ~event_id:id ct = Some (value_for id)))
        [ "e1"; "e2" ];
      (* And store's own kek never moved -- the failed, wrong-key resume changed nothing about
         [t] itself, regardless of whether "e3" got rewritten to kek3 along the way before the
         exception fired. *)
      let after_ct = Redaction_store.encrypt_for_storage store ~event_id:"after" (value_for "after") in
      Alcotest.(check bool) "store's own kek is unchanged after the failed, wrong-key resume" true
        (Redaction_store.decrypt_with store ~kek:kek1 ~event_id:"after" after_ct = Some (value_for "after")))

let test_rotate_kek_raises_on_an_entry_undecryptable_under_either_key () =
  with_two_kek_store (fun ~kv ~kek1 ~kek2:new_kek ~store ->
      let good_ct = Redaction_store.encrypt_for_storage store ~event_id:"good" (value_for "good") in
      (* A real, durably-stored, correctly length-prefixed record whose wrapped-DEK bytes are
         simply garbage -- authenticates under neither kek1 nor new_kek. This is the "data
         corruption unrelated to rotation" scenario redaction_store.mli's [rotate_kek] doc
         describes, not a rotation bug -- planted directly via File_kv_store.put, the same way a
         foreign write or a genuinely corrupt entry would arrive, bypassing Redaction_store's own
         write path entirely (same technique test_enumerate_event_ids_skips_an_undecodable_record_
         without_raising already uses for a different, decode-level failure). *)
      Riptide_storage.File_kv_store.put kv ~key:"corrupt"
        (build_record ~event_id:"corrupt" "not-a-real-wrapped-dek-at-all");
      Alcotest.check_raises "an entry unreadable under either key stops the rotation, loudly"
        (Redaction_store.Undecryptable_entry "corrupt")
        (fun () -> Redaction_store.rotate_kek store ~new_kek);
      (* The good, pre-existing entry survives the failed rotation -- either it was already
         rotated to new_kek before the exception fired, or it was never reached; either way it is
         readable under exactly one of the two keys, never destroyed. *)
      Alcotest.(check bool)
        "the good entry is still readable after the failed rotation, under whichever key applies"
        true
        (Redaction_store.decrypt_with store ~kek:kek1 ~event_id:"good" good_ct = Some (value_for "good")
        || Redaction_store.decrypt_with store ~kek:new_kek ~event_id:"good" good_ct
           = Some (value_for "good"));
      (* [store]'s own kek never switched -- the exception fired before rotate_kek's own final
         assignment could run. A fresh encrypt through the same [store] after the failed rotation
         still uses the OLD key, proving this directly rather than relying on an internal field no
         public API exposes. *)
      let after_ct = Redaction_store.encrypt_for_storage store ~event_id:"after" (value_for "after") in
      Alcotest.(check bool) "store's own kek is unchanged after a failed rotation" true
        (Redaction_store.decrypt_with store ~kek:kek1 ~event_id:"after" after_ct = Some (value_for "after")))

(* -- Subtask 4.8's [Redaction_store] half: [create] must itself verify [kv] was actually built
   with its own [owner_tag], not just document the convention every real call site already
   follows. Closes ONE gap left open by subtask 4.6/the layer0-followup-hardening plan: this
   function receives an already-built [kv], so [File_kv_store.create]'s own owner-marker guard used
   to protect a caller of THIS function only if that caller had tagged [kv] at all, and nothing here
   could tell whether it had -- this test pins that [create] now enforces the tag directly, rather
   than trusting the caller. (A companion test used to also cover an untagged [kv] -- [~owner]
   omitted entirely -- but that state stopped being constructible once [File_kv_store.create]'s own
   [~owner] became mandatory, so it was removed rather than adapted.)

   What this check does NOT close, and it is disclosed rather than fixed: a [kv] tagged with exactly
   [Redaction_store.owner_tag] is accepted, which is correct for this keystore's own store but is
   equally accepted when an unrelated consumer shares that directory under the same tag -- the pair
   then destroys each other's data silently. See
   [test_lattice_materialize_crypto_scenarios.ml]'s
   [test_using_the_same_owner_tag_on_both_sides_still_destroys_a_wrapped_dek] for the running proof,
   and redaction_store.mli's own [create] doc for why closing it is out of scope here. *)

let test_create_rejects_a_kv_tagged_for_a_different_owner () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv =
        Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"some-other-owner" dir
      in
      let kek = Kek.of_raw (Mirage_crypto_rng.generate 32) in
      Alcotest.check_raises "a kv tagged for a different owner is rejected at construction"
        (Invalid_argument
           (Printf.sprintf "Redaction_store.create: kv is owned by %S, expected %S" "some-other-owner"
              Redaction_store.owner_tag))
        (fun () -> ignore (Redaction_store.create ~kv ~kek)))

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
    ~send:(fun ~to_:_ (_ : string) -> ()) ()

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
        Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:Redaction_store.owner_tag
          dir
      in
      let store = Redaction_store.create ~kv ~kek:(Kek.of_raw (Mirage_crypto_rng.generate 32)) in
      (* Carries the SENDING replica's own id alongside [to_]/[bytes] -- each replica's [~send]
         closure below closes over its own [i + 1], the real (in-process, but genuine) identity of
         whoever is calling [send], exactly the role a real transport's authenticated connection
         plays for [handle_message]'s new [~sender] cross-check (Task 3). *)
      let inflight : (int * int * string) Queue.t = Queue.create () in
      let replicas =
        Array.init replica_count (fun i ->
            Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:(i + 1) ~replica_count
              ~svc_limit:3 ~send:(fun ~to_ bytes -> Queue.add (to_, i + 1, bytes) inflight) ())
      in
      (* Same reason every cluster harness in this repo does this (see test_batch_commit_cluster.ml
         and Riptide_dst.Cluster): a fresh replica starts at view 0, where Primary(0) =
         replica_count, so replicas.(0) would NOT be the primary and every propose against it
         would be a silent no-op. Primary(1) = 1 for any replica_count. All replicas must be
         pinned to the same view or they reject each other's messages outright. *)
      Array.iter (fun r -> Replica.for_test_set_view_number r 1) replicas;
      let deliver_all () =
        while not (Queue.is_empty inflight) do
          let to_, sender, bytes = Queue.pop inflight in
          Replica.handle_message replicas.(to_ - 1) ~sender bytes
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
    ( "create rejects a kv tagged for a different owner",
      `Quick,
      test_create_rejects_a_kv_tagged_for_a_different_owner );
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
    ( "Task 24: enumerate_event_ids recovers every event_id with no external log",
      `Quick,
      test_enumerate_event_ids_recovers_every_event_id_with_no_external_log );
    ( "Task 24 review (Important): enumerate_event_ids skips an undecodable record without raising",
      `Quick,
      test_enumerate_event_ids_skips_an_undecodable_record_without_raising );
    ( "Task 24 review (Important): enumerate_event_ids skips a hash whose record fails its own \
       checksum without raising",
      `Quick,
      test_enumerate_event_ids_skips_a_hash_whose_record_fails_durable_read_without_raising );
    ( "Task 24: enumerate_event_ids does not include a redacted event_id",
      `Quick,
      test_enumerate_event_ids_does_not_include_a_redacted_event_id );
    ( "Task 25: rotate_kek re-wraps every entry and the old KEK no longer decrypts",
      `Quick,
      test_rotate_kek_re_wraps_every_entry_and_old_kek_no_longer_decrypts );
    ( "Task 25: rotate_kek interrupted partway leaves a readable mix, not torn entries",
      `Quick,
      test_rotate_kek_interrupted_partway_leaves_a_readable_mix_not_torn_entries );
    ( "Task 25: a second rotate_kek call after a partial failure is resumable",
      `Quick,
      test_rotate_kek_second_call_after_a_partial_failure_is_resumable );
    ( "Task 25 re-review (Important): resuming with a different new_kek than the abandoned \
       attempt raises on an intact entry",
      `Quick,
      test_rotate_kek_resumed_with_a_different_new_kek_than_the_abandoned_attempt_raises );
    ( "Task 25: rotate_kek raises on an entry undecryptable under either key",
      `Quick,
      test_rotate_kek_raises_on_an_entry_undecryptable_under_either_key );
  ]
