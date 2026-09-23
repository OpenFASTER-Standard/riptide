(** AES-256-GCM with a deterministic, per-DEK monotonic counter nonce
    (NIST SP 800-38D §8.2.1's permitted construction — never a randomly
    generated nonce, which carries a real collision risk under GCM's
    96-bit nonce at high encryption counts; design spec Decision 4). *)

type t = {
  key_bytes : string; (* retained alongside the constructed key below --
                          Mirage_crypto.AES.GCM.key is abstract, with no
                          accessor recovering the original secret, and
                          Task 6 needs these raw bytes to wrap a DEK under
                          the KEK. *)
  key : Mirage_crypto.AES.GCM.key;
  nonce_prefix : string;
  counter : int64 ref;
}

(* GCM's nonce is 12 bytes: a fixed 4-byte prefix (random, chosen once per
   DEK, to keep two different DEKs' counter sequences from ever colliding
   even if both started their counters at 0) plus an 8-byte big-endian
   monotonic counter. *)
let nonce_of t =
  let n = !(t.counter) in
  t.counter := Int64.add n 1L;
  let buf = Bytes.create 12 in
  Bytes.blit_string t.nonce_prefix 0 buf 0 4;
  Bytes.set_int64_be buf 4 n;
  Bytes.unsafe_to_string buf

let of_key_bytes key_bytes =
  { key_bytes; key = Mirage_crypto.AES.GCM.of_secret key_bytes; nonce_prefix = Mirage_crypto_rng.generate 4; counter = ref 0L }

let generate () = of_key_bytes (Mirage_crypto_rng.generate 32)
let of_raw raw_bytes = of_key_bytes raw_bytes
let raw t = t.key_bytes

let encrypt t plaintext =
  let nonce = nonce_of t in
  let ciphertext = Mirage_crypto.AES.GCM.authenticate_encrypt ~key:t.key ~nonce plaintext in
  (* the nonce is not secret, only the key is -- it must travel with the
     ciphertext so decrypt can recover it, hence prepended here. *)
  nonce ^ ciphertext

let decrypt t nonce_and_ciphertext =
  if String.length nonce_and_ciphertext < 12 then None
  else
    let nonce = String.sub nonce_and_ciphertext 0 12 in
    let ciphertext = String.sub nonce_and_ciphertext 12 (String.length nonce_and_ciphertext - 12) in
    Mirage_crypto.AES.GCM.authenticate_decrypt ~key:t.key ~nonce ciphertext
