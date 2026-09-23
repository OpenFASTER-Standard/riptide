(** The redaction keystore: a fresh, independent DEK per record, wrapped under the shared KEK and
    stored outside everything the envelope's content hash covers, so redaction is exactly one
    keystore deletion. See redaction_store.mli for the full design argument (Decision 4), the
    meaning of [event_id] here, and why it is not the envelope's own event_id. *)

type t = { kv : Riptide_storage.File_kv_store.t; kek : Kek.t }

let create ~kv ~kek = { kv; kek }

(* The DEK's raw bytes, encrypted under the KEK with the record's own event_id bound in as GCM
   additional authenticated data -- so a wrapped DEK moved to a different keystore slot fails to
   authenticate instead of silently decrypting the wrong record. See kek.mli for why wrapping uses
   Kek's own freshly-nonced GCM rather than Dek.encrypt on a Dek.of_raw-reconstructed KEK (whose
   counter resets to zero on every reconstruction, collapsing the nonce entropy to 32 bits). *)
let wrap_dek t ~event_id (dek : Dek.t) = Kek.wrap t.kek ~aad:event_id (Dek.raw dek)

let unwrap_dek t ~event_id wrapped =
  match Kek.unwrap t.kek ~aad:event_id wrapped with
  | None -> None
  (* Dek.of_raw raises Invalid_argument on anything that isn't exactly 32 bytes. GCM
     authentication already makes a wrong-length unwrap result essentially unreachable without the
     KEK itself, but this module's whole contract is "None, never an exception" on the failure
     path, so the length is checked here rather than trusted. *)
  | Some raw when String.length raw <> 32 -> None
  | Some raw -> Some (Dek.of_raw raw)

let encrypt_for_storage t ~event_id (v : Riptide.Value.value) =
  let dek = Dek.generate () in
  let ciphertext = Dek.encrypt dek (Riptide.Value.canonical_encode v) in
  (* Strictly before returning, hence strictly before the caller can write the ciphertext
     anywhere: a crash here loses an orphan DEK for a ciphertext that was never stored, whereas
     the reverse order would lose a real record permanently. *)
  Riptide_storage.File_kv_store.put t.kv ~key:event_id (wrap_dek t ~event_id dek);
  ciphertext

let decrypt t ~event_id ciphertext =
  match Riptide_storage.File_kv_store.get t.kv ~key:event_id with
  | None -> None (* redacted, never stored, or the stored entry failed its own checksum *)
  | Some wrapped -> (
    match unwrap_dek t ~event_id wrapped with
    | None -> None
    | Some dek -> (
      match Dek.decrypt dek ciphertext with
      | None -> None
      | Some plaintext -> (
        (* A payload that authenticated under its own DEK but does not decode is not something any
           honest write path can produce; it still must not escape as an exception from a function
           documented to return an option. *)
        try Some (Riptide.Value.canonical_decode plaintext) with Invalid_argument _ -> None)))

let redact t ~event_id = Riptide_storage.File_kv_store.delete t.kv ~key:event_id

let payload_of_ciphertext ct = Riptide.Value.Scalar (Riptide.Value.Bytes ct)
let encrypt_value t ~event_id v = payload_of_ciphertext (encrypt_for_storage t ~event_id v)

let decrypt_value t ~event_id (payload : Riptide.Value.value) =
  match payload with
  | Riptide.Value.Scalar (Riptide.Value.Bytes ciphertext) -> decrypt t ~event_id ciphertext
  | _ -> None
