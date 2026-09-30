(** The redaction keystore: a fresh, independent DEK per record, wrapped under the shared KEK and
    stored outside everything the envelope's content hash covers, so redaction is exactly one
    keystore deletion. See redaction_store.mli for the full design argument (Decision 4), the
    meaning of [event_id] here, and why it is not the envelope's own event_id. *)

type t = { kv : Riptide_storage.File_kv_store.t; kek : Kek.t }

let owner_tag = "redaction-keystore"

let create ~kv ~kek =
  let actual = Riptide_storage.File_kv_store.owner kv in
  if actual <> owner_tag then
    invalid_arg
      (Printf.sprintf "Redaction_store.create: kv is owned by %S, expected %S" actual owner_tag);
  { kv; kek }

(* The DEK's raw bytes, encrypted under the KEK with the record's own event_id bound in as GCM
   additional authenticated data -- so a wrapped DEK moved to a different keystore slot fails to
   authenticate instead of silently decrypting the wrong record. See kek.mli for why wrapping uses
   Kek's own freshly-nonced GCM rather than Dek.encrypt on a Dek.of_raw-reconstructed KEK (whose
   counter resets to zero on every reconstruction, collapsing the nonce entropy to 32 bits). *)
let wrap_dek t ~event_id (dek : Dek.t) = Kek.wrap t.kek ~aad:event_id (Dek.raw dek)

(* Task 24: this keystore's own on-disk record format, as of this task -- [event_id] (in the
   clear; see redaction_store.mli's own note on why that is not a new secrecy hole) followed
   immediately by the wrapped-DEK bytes {!wrap_dek} produces. Needed because
   {!Riptide_storage.File_kv_store}'s own key space is hashed away before it ever reaches disk
   (see {!Riptide_storage.Kv_store_intf.S.fold}'s doc comment): enumerating this keystore's
   contents via {!Riptide_storage.File_kv_store.fold} can only ever recover the store's own
   internal (hash) identifiers, never the [event_id]s that produced them, unless [event_id] is
   itself carried inside the stored VALUE. {!enumerate_event_ids} below is what this format makes
   possible.

   Length-prefixed rather than delimiter-separated, for the same reason
   {!Riptide_batch_commit.Batch_commit.redaction_event_id} already length-prefixes its own
   idempotency key (see batch_commit.ml): [event_id] is an opaque, caller-supplied string that
   could contain any byte, including whatever delimiter a fixed-separator scheme might otherwise
   pick, and the wrapped-DEK bytes that follow it are equally opaque, arbitrary bytes -- so the
   only injective encoding available without escaping either side is "how many bytes of event_id
   are there", read off the front. *)
let encode_record ~event_id wrapped = Printf.sprintf "%d:%s%s" (String.length event_id) event_id wrapped

(* Inverse of [encode_record]. [None] on anything that does not parse as that exact shape --
   see [enumerate_event_ids] below and [unwrap_dek]'s own comment for how each of this function's
   two callers treats that outcome, and why differently. *)
let decode_record raw =
  match String.index_opt raw ':' with
  | None -> None
  | Some colon_idx -> (
    match int_of_string_opt (String.sub raw 0 colon_idx) with
    | None -> None
    | Some len when len < 0 || colon_idx + 1 + len > String.length raw -> None
    | Some len ->
      let event_id = String.sub raw (colon_idx + 1) len in
      let wrapped = String.sub raw (colon_idx + 1 + len) (String.length raw - colon_idx - 1 - len) in
      Some (event_id, wrapped))

let unwrap_dek t ~event_id record =
  match decode_record record with
  | None -> None
  | Some (_embedded_event_id, wrapped) ->
    (* Judgment call (Task 24): the decoded [_embedded_event_id] is deliberately IGNORED here, not
       cross-checked against [event_id] (the caller-supplied lookup key). Two reasons, not one:

       1. It is not needed for correctness. [Kek.unwrap] below always authenticates under the
          CALLER-SUPPLIED [event_id] as AAD, never the embedded copy -- that is what actually
          defeats the real attack {!Kek.wrap}'s AAD binding exists for (moving a whole wrapped-DEK
          record from one keystore slot to another and hoping it silently authenticates there): see
          test_wrapped_dek_is_bound_to_its_event_id in test_redaction.ml. Trusting the embedded copy
          for AAD instead would let an attacker who relocates a whole record carry its own embedded
          event_id along for the ride and have it authenticate under ITSELF at the new slot,
          defeating the binding entirely -- so the embedded copy must never substitute for the
          argument here, only [get]'s own KV key may.
       2. Adding a plain string-equality gate here (reject if [_embedded_event_id <> event_id],
          before ever reaching [Kek.unwrap]) was considered and deliberately rejected, not merely
          not thought of: it would make the exact swap attack in
          test_wrapped_dek_is_bound_to_its_event_id above fail EARLIER, on a plaintext comparison,
          before [Kek.unwrap] (and therefore the AAD binding) is ever exercised at all -- which is
          precisely the false-positive shape that test's own comment already documents once
          happening to this same test for a different reason (a keystore MISS alone masking the
          GCM/AAD path never being reached). A cheap plaintext gate would silently reintroduce that
          exact risk: if the AAD were ever accidentally dropped from {!Kek.wrap}/{!Kek.unwrap}, this
          gate alone would keep the attack blocked and the test green, hiding a real cryptographic
          regression behind a check that has nothing to do with cryptography. So the embedded copy
          is read only by {!enumerate_event_ids} below, which has no security property riding on
          it, never here. *)
    (match Kek.unwrap t.kek ~aad:event_id wrapped with
    | None -> None
    (* Dek.of_raw raises Invalid_argument on anything that isn't exactly 32 bytes. GCM
       authentication already makes a wrong-length unwrap result essentially unreachable without
       the KEK itself, but this module's whole contract is "None, never an exception" on the
       failure path, so the length is checked here rather than trusted. *)
    | Some raw when String.length raw <> 32 -> None
    | Some raw -> Some (Dek.of_raw raw))

let encrypt_for_storage t ~event_id (v : Riptide.Value.value) =
  let dek = Dek.generate () in
  (* M4 (task-6 review): can raise Invalid_argument, inherited from canonical_encode, if
     [v] contains a duplicate-keyed Record/Map anywhere in it - before this task,
     canonical_encode never raised at all. *)
  let ciphertext = Dek.encrypt dek (Riptide.Value.canonical_encode v) in
  (* Strictly before returning, hence strictly before the caller can write the ciphertext
     anywhere: a crash here loses an orphan DEK for a ciphertext that was never stored, whereas
     the reverse order would lose a real record permanently. *)
  Riptide_storage.File_kv_store.put t.kv ~key:event_id (encode_record ~event_id (wrap_dek t ~event_id dek));
  ciphertext

let decrypt t ~event_id ciphertext =
  match Riptide_storage.File_kv_store.get t.kv ~key:event_id with
  | None -> None (* redacted, never stored, or the stored entry failed its own checksum *)
  | Some record -> (
    match unwrap_dek t ~event_id record with
    | None -> None
    | Some dek -> (
      match Dek.decrypt dek ciphertext with
      | None -> None
      | Some plaintext -> (
        (* A payload that authenticated under its own DEK but does not decode is not something any
           honest write path can produce; it still must not escape as an exception from a function
           documented to return an option. *)
        try Some (Riptide.Value.canonical_decode plaintext) with Invalid_argument _ -> None)))

(* Task 24: recovers the full set of event_ids this keystore currently holds a wrapped DEK for,
   with no external log replay needed -- see this module's own [.mli] doc on [enumerate_event_ids]
   for why this was previously impossible (this store's KV key space is hashed away before it ever
   reaches disk) and how embedding [event_id] in the VALUE, above, fixes that.

   Folds over {!Riptide_storage.File_kv_store.fold}'s own internal (hash) identifiers, reads each
   one back via {!Riptide_storage.File_kv_store.get_by_hash} (never [get] -- see that function's
   own doc for why [get] cannot be used with a hash fold hands back), and decodes the embedded
   event_id out of whatever record is found there.

   {b Two distinct "missing" outcomes below, treated deliberately differently, per this task's own
   instruction not to silently swallow what should be impossible:}
   - [get_by_hash] returning [None] (the record was deleted -- e.g. a concurrent {!redact} -- or
     failed its own checksum, between [fold]'s directory listing and this read) is an ORDINARY,
     expected race on a live store, exactly the same "cannot distinguish never-written from
     corrupted" ambiguity {!Riptide_storage.Kv_store_intf.S.get} already documents. Skipped
     silently, the same way a caller retrying a lookup after a redaction would see nothing there
     either.
   - [decode_record] failing on bytes that DID read back successfully is a different matter: every
     record in this keystore's own directory is written exclusively by this module's own
     {!encrypt_for_storage}, always via [encode_record], so a successfully-checksummed record that
     does not decode as that exact format should be impossible for a keystore this module fully
     controls -- either a bug in this module, or a foreign write into what {!create}'s own [~owner]
     guard is supposed to keep this keystore's directory exclusive to. Per this task's own explicit
     instruction, this function SKIPS such a record rather than raising: one malformed record must
     not prevent enumerating every other, good one, matching {!decrypt}'s own established "never an
     exception" discipline on this exact keystore. {b Stated honestly rather than glossed over:}
     this codebase has no logging/diagnostics facility to surface a "this should be impossible"
     condition through short of raising (confirmed by grep -- {!Riptide.Log} is the hash-chained
     envelope log, an unrelated concept despite the name, not a diagnostics log), so choosing not
     to raise here really does mean this specific failure mode -- a foreign write, or a bug in this
     module's own encode/decode pair -- would go unreported by this function alone. Nothing else in
     [encrypt_for_storage]'s own write path can produce it, and {!create}'s own [~owner] guard (see
     [redaction_store.mli]) is this codebase's actual defense against the "foreign write" half of
     that risk; this function's own silence on a decode failure is a deliberately accepted,
     disclosed gap, not an oversight. *)
let enumerate_event_ids t =
  Riptide_storage.File_kv_store.fold t.kv ~init:[] (fun ~key acc ->
      match Riptide_storage.File_kv_store.get_by_hash t.kv ~hash:key with
      | None -> acc
      | Some record -> (
        match decode_record record with
        | Some (event_id, _wrapped) -> event_id :: acc
        | None -> acc))

let redact t ~event_id = Riptide_storage.File_kv_store.delete t.kv ~key:event_id

let payload_of_ciphertext ct = Riptide.Value.Scalar (Riptide.Value.Bytes ct)
let encrypt_value t ~event_id v = payload_of_ciphertext (encrypt_for_storage t ~event_id v)

let decrypt_value t ~event_id (payload : Riptide.Value.value) =
  match payload with
  | Riptide.Value.Scalar (Riptide.Value.Bytes ciphertext) -> decrypt t ~event_id ciphertext
  | _ -> None
