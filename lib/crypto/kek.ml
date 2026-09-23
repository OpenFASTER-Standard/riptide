(** The Key Encryption Key: externally-sourced AES-256 key material, plus the AES-256-GCM
    wrap/unwrap used to protect every per-record DEK at rest. See kek.mli for the full argument
    -- in particular for why this module does its own GCM wrapping with a freshly generated
    96-bit nonce (NIST SP 800-38D §8.2.2's RBG-based construction) instead of reusing
    [Dek.encrypt] on a [Dek.of_raw]-reconstructed KEK, whose counter reset to zero would collapse
    the nonce's entropy to the 32-bit prefix space (~2^16 wraps to a 50% collision). *)

(* Just the constructed GCM key -- unlike [Dek.t], this module deliberately retains no copy of the
   raw bytes and exposes no [raw]: nothing outside here ever needs the KEK's own material back
   out, and not keeping a second copy is one less place it can leak from. *)
type t = Mirage_crypto.AES.GCM.key

let key_length = 32
let nonce_length = 12

let of_raw raw_bytes =
  if String.length raw_bytes <> key_length then
    invalid_arg
      (Printf.sprintf "Kek.of_raw: expected exactly %d bytes (AES-256), got %d" key_length
         (String.length raw_bytes));
  Mirage_crypto.AES.GCM.of_secret raw_bytes

(* Decision 5's "permissions-restricted file", checked rather than assumed. 0o077 is every group
   and other bit (read, write, execute): a KEK any other local account can read is not a secret,
   and silently accepting one would make the whole redaction design decorative. Deliberately
   checked via the already-open descriptor (Unix.fstat), not the path (Unix.stat), so nothing can
   swap the file between the check and the read. *)
let check_permissions ~path fd =
  let st = Unix.fstat fd in
  if st.Unix.st_perm land 0o077 <> 0 then
    invalid_arg
      (Printf.sprintf "Kek.load: %s has mode %04o, which grants access to group or other; a KEK file must be 0600 or stricter"
         path st.Unix.st_perm)

let load ~path =
  (* open_in_bin raises Sys_error for a missing/unopenable file, which load's own documented
     contract deliberately propagates: a process that cannot load its KEK must fail to start
     rather than continue with any other key. *)
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      check_permissions ~path (Unix.descr_of_in_channel ic);
      let len = in_channel_length ic in
      if len <> key_length then
        invalid_arg
          (Printf.sprintf "Kek.load: %s is %d bytes, expected exactly %d" path len key_length);
      of_raw (really_input_string ic key_length))

let wrap t ~aad raw_dek =
  let nonce = Mirage_crypto_rng.generate nonce_length in
  nonce ^ Mirage_crypto.AES.GCM.authenticate_encrypt ~key:t ~nonce ~adata:aad raw_dek

let unwrap t ~aad wrapped =
  if String.length wrapped < nonce_length then None
  else
    let nonce = String.sub wrapped 0 nonce_length in
    let ciphertext = String.sub wrapped nonce_length (String.length wrapped - nonce_length) in
    Mirage_crypto.AES.GCM.authenticate_decrypt ~key:t ~nonce ~adata:aad ciphertext
