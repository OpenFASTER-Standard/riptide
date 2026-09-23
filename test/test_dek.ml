open Riptide_crypto

let () = Mirage_crypto_rng_unix.use_default ()

let test_roundtrip () =
  let dek = Dek.generate () in
  let ct = Dek.encrypt dek "hello world" in
  Alcotest.(check (option string)) "decrypts to the original" (Some "hello world") (Dek.decrypt dek ct)

let test_wrong_key_fails_to_decrypt () =
  let dek1 = Dek.generate () and dek2 = Dek.generate () in
  let ct = Dek.encrypt dek1 "secret" in
  Alcotest.(check (option string)) "wrong key fails auth" None (Dek.decrypt dek2 ct)

let test_ciphertext_is_not_plaintext () =
  let dek = Dek.generate () in
  let ct = Dek.encrypt dek "plaintext-marker" in
  Alcotest.(check bool) "ciphertext does not contain the plaintext bytes" false
    (try ignore (Str.search_forward (Str.regexp_string "plaintext-marker") ct 0); true
     with Not_found -> false)

(* Review Focus (fix round, Finding 1): the original version of this test encrypted 10,000
   *distinct* plaintexts and checked the ciphertexts were pairwise distinct. That proves
   nothing about nonce reuse -- GCM is a stream cipher, so distinct plaintexts always
   produce distinct ciphertexts regardless of whether the nonce repeats. This version
   instead inspects the nonce bytes directly (bytes 0-11 of each ciphertext) and asserts
   the actual invariants Dek's design depends on: a stable 4-byte prefix, a strictly
   ascending 8-byte counter with no gaps or repeats, starting at 0. *)
let test_nonce_prefix_and_counter_sequence_are_correct () =
  let dek = Dek.generate () in
  let ciphertexts = List.init 10_000 (fun i -> Dek.encrypt dek (Printf.sprintf "msg-%d" i)) in
  let nonces = List.map (fun ct -> String.sub ct 0 12) ciphertexts in
  let unique_nonces = List.sort_uniq compare nonces in
  Alcotest.(check int) "every nonce is distinct (no nonce collision)" 10_000 (List.length unique_nonces);
  let prefixes = List.sort_uniq compare (List.map (fun n -> String.sub n 0 4) nonces) in
  Alcotest.(check int) "all 10,000 nonces share the same 4-byte prefix (same DEK)" 1 (List.length prefixes);
  let counters = List.map (fun n -> String.get_int64_be n 4) nonces in
  let expected = List.init 10_000 (fun i -> Int64.of_int i) in
  Alcotest.(check bool) "the 8-byte counter is exactly the ascending sequence 0..9999, in order" true
    (counters = expected);
  List.iteri
    (fun i ct ->
      Alcotest.(check (option string)) (Printf.sprintf "message %d round-trips" i)
        (Some (Printf.sprintf "msg-%d" i)) (Dek.decrypt dek ct))
    ciphertexts

(* This variant has real power to catch nonce reuse: encrypting the SAME plaintext many
   times means a repeated nonce would produce a byte-identical GCM ciphertext (GCM's
   keystream depends only on key+nonce, and CTR-mode-style XOR of an identical keystream
   against an identical plaintext yields an identical result), unlike the distinct-plaintext
   version this replaces which passed even against a hard-coded constant nonce. *)
let test_same_plaintext_encrypted_many_times_never_collides () =
  let dek = Dek.generate () in
  let ciphertexts = List.init 10_000 (fun _ -> Dek.encrypt dek "the same message, every time") in
  let unique = List.sort_uniq compare ciphertexts in
  Alcotest.(check int) "10,000 encryptions of the same plaintext are all distinct" 10_000 (List.length unique)

let test_different_deks_get_different_nonce_prefixes () =
  (* Proves cross-DEK prefix randomness, not just within-DEK counter advancement --
     two fresh DEKs' first nonces must not share a 4-byte prefix, or their independent
     counter sequences (each starting at 0) would collide immediately. *)
  let dek1 = Dek.generate () and dek2 = Dek.generate () in
  let prefix_of dek = String.sub (Dek.encrypt dek "x") 0 4 in
  Alcotest.(check bool) "two fresh DEKs get different 4-byte nonce prefixes" true
    (prefix_of dek1 <> prefix_of dek2)

let tests =
  [
    ("roundtrip", `Quick, test_roundtrip);
    ("wrong key fails to decrypt", `Quick, test_wrong_key_fails_to_decrypt);
    ("ciphertext is not plaintext", `Quick, test_ciphertext_is_not_plaintext);
    ("nonce prefix is stable and counter sequence is correct", `Quick, test_nonce_prefix_and_counter_sequence_are_correct);
    ("same plaintext encrypted many times never collides", `Quick, test_same_plaintext_encrypted_many_times_never_collides);
    ("different DEKs get different nonce prefixes", `Quick, test_different_deks_get_different_nonce_prefixes);
  ]
