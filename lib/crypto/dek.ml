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
  counter : int Atomic.t;
  (* A native OCaml [int] (63-bit on 64-bit platforms), not [int64]: this
     lets [nonce_of] use [Atomic.fetch_and_add] for a lock-free,
     race-free read-then-increment (an [int64 ref] can't participate in
     [Atomic] -- OCaml 5's atomics are only over the native, unboxed
     [int]/immediate-value width). 2^62 nonces is still far past the 2^32
     NIST SP 800-38D §8.3 bound this construction is limited to anyway
     (see the .mli), so the narrower range costs nothing in practice. The
     8-byte big-endian counter field in the nonce is still encoded via
     [Int64.of_int], which is exact for any non-negative value this
     counter will ever hold. *)
}

(* GCM's nonce is 12 bytes: a fixed 4-byte prefix (random, chosen once per
   DEK, to keep two different DEKs' counter sequences from ever colliding
   even if both started their counters at 0) plus an 8-byte big-endian
   monotonic counter. *)
let nonce_of t =
  let n = Atomic.fetch_and_add t.counter 1 in
  let buf = Bytes.create 12 in
  Bytes.blit_string t.nonce_prefix 0 buf 0 4;
  Bytes.set_int64_be buf 4 (Int64.of_int n);
  Bytes.unsafe_to_string buf

let of_key_bytes key_bytes =
  if String.length key_bytes <> 32 then invalid_arg "Dek.of_raw: expected 32-byte key";
  { key_bytes; key = Mirage_crypto.AES.GCM.of_secret key_bytes; nonce_prefix = Mirage_crypto_rng.generate 4; counter = Atomic.make 0 }

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
