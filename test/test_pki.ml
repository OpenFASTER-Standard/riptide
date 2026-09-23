(* Tests for [Riptide_pki.Ca] -- the self-managed PKI Task 8 will wire into real mTLS.

   Every [x509] API call exercised here was verified against the real installed library
   (`x509` 1.2.0, `/work/toolchain/opam-root/5.0.0/lib/x509/x509.mli`) and, where the exact
   acceptance rule mattered, against its actual implementation (`lib/validation.ml` of the
   `x509.1.2.0` source, fetched with `opam source`) -- not against the plan's assumed
   signatures. Three of the plan's own assumed calls were wrong; see `task-7-report.md` and the
   header of `lib/pki/ca.ml` for the details. The corrections applied here:

   - [X509.Validation.verify_chain_of_trust] takes [~time:(unit -> Ptime.t option)], a *thunk
     returning an option*, not a [Ptime.t], and [~host] is a *required* labelled argument (its
     value is an option, the argument is not).
   - It returns [(_, validation_error) result], so its errors print with
     [pp_validation_error]; [pp_chain_error] is a different type and does not typecheck here.
   - [X509.Distinguished_name.t] is a list of [Set.S] values holding abstract
     [Encoded_string.t]s, so structural [=] on it is not a meaningful comparison --
     [X509.Distinguished_name.equal] is. *)

open Riptide_pki

let now () = Ptime_clock.now ()
let time_thunk () = Some (now ())

let host s = Domain_name.(host_exn (of_string_exn s))

let span_days d =
  match Ptime.Span.of_d_ps (d, 0L) with
  | Some s -> s
  | None -> Alcotest.fail "test bug: bad day span"

let shift t d =
  match Ptime.add_span t (span_days d) with
  | Some t -> t
  | None -> Alcotest.fail "test bug: Ptime overflow"

(* [valid_ca] is the real cryptographic self-signature check: its implementation runs
   [is_self_signed && version_matches_extensions && validate_signature cert cert &&
   validate_time && valid_trust_anchor_extensions]. Comparing subject to issuer alone (what the
   plan's test did) proves only that two name fields match -- it does not prove the root's own
   signature verifies under its own key, which is the property that actually makes it a root. *)
let test_root_is_a_genuine_self_signed_ca () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  Alcotest.(check bool)
    "root cert's issuer matches its own subject" true
    (X509.Distinguished_name.equal
       (X509.Certificate.subject ca.Ca.cert)
       (X509.Certificate.issuer ca.Ca.cert));
  match X509.Validation.valid_ca ~time:(now ()) ca.Ca.cert with
  | Ok () -> ()
  | Error e -> Alcotest.fail (Fmt.to_to_string X509.Validation.pp_ca_error e)

let test_root_cert_matches_root_private_key () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  Alcotest.(check string)
    "cert's public key is the private key's public key"
    (X509.Public_key.fingerprint (X509.Private_key.public ca.Ca.key))
    (X509.Public_key.fingerprint (X509.Certificate.public_key ca.Ca.cert))

let test_sign_leaf_produces_a_cert_the_root_validates () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  let leaf_cert, _leaf_key = Ca.sign_leaf ca ~common_name:"replica-1" ~valid_days:365 in
  match
    X509.Validation.verify_chain_of_trust ~host:None ~time:time_thunk ~anchors:[ ca.Ca.cert ]
      [ leaf_cert ]
  with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Fmt.to_to_string X509.Validation.pp_validation_error e)

let test_leaf_signed_by_unrelated_ca_is_rejected () =
  let ca1 = Ca.generate_root ~common_name:"ca-one" in
  let ca2 = Ca.generate_root ~common_name:"ca-two" in
  let leaf_cert, _ = Ca.sign_leaf ca2 ~common_name:"replica-x" ~valid_days:365 in
  match
    X509.Validation.verify_chain_of_trust ~host:None ~time:time_thunk ~anchors:[ ca1.Ca.cert ]
      [ leaf_cert ]
  with
  | Ok _ ->
    Alcotest.fail "a leaf signed by an unrelated CA must not validate against a different anchor"
  | Error _ -> ()

(* Task 8's mTLS peer verification identifies a replica by name, which only works if the leaf
   carries a SubjectAlternativeName. [X509.Certificate.hostnames] reads DNS SAN entries *only*
   (verified in `certificate.ml`) -- a CN alone is not enough, so this is a real requirement of
   the next task, not decoration. *)
let test_leaf_is_valid_for_its_own_hostname () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  let leaf_cert, _ = Ca.sign_leaf ca ~common_name:"replica-1" ~valid_days:365 in
  match
    X509.Validation.verify_chain_of_trust
      ~host:(Some (host "replica-1"))
      ~time:time_thunk ~anchors:[ ca.Ca.cert ] [ leaf_cert ]
  with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Fmt.to_to_string X509.Validation.pp_validation_error e)

let test_leaf_is_rejected_for_a_different_hostname () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  let leaf_cert, _ = Ca.sign_leaf ca ~common_name:"replica-1" ~valid_days:365 in
  match
    X509.Validation.verify_chain_of_trust
      ~host:(Some (host "replica-2"))
      ~time:time_thunk ~anchors:[ ca.Ca.cert ] [ leaf_cert ]
  with
  | Ok _ -> Alcotest.fail "a leaf must not validate for a hostname it was not issued for"
  | Error _ -> ()

(* A leaf that is itself a usable CA would let any compromised replica mint certificates the
   whole cluster trusts. The root is pathlen-0 too, so even a forged intermediate cannot chain. *)
let test_leaf_is_not_itself_a_ca () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  let leaf_cert, _ = Ca.sign_leaf ca ~common_name:"replica-1" ~valid_days:365 in
  (match X509.Extension.find X509.Extension.Basic_constraints (X509.Certificate.extensions leaf_cert) with
   | Some (_, (is_ca, _)) -> Alcotest.(check bool) "leaf BasicConstraints CA" false is_ca
   | None -> Alcotest.fail "leaf must carry an explicit BasicConstraints extension");
  match X509.Validation.valid_ca ~time:(now ()) leaf_cert with
  | Ok () -> Alcotest.fail "a leaf certificate must not pass as a valid CA"
  | Error _ -> ()

let test_root_is_a_pathlen_zero_ca () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  match X509.Extension.find X509.Extension.Basic_constraints (X509.Certificate.extensions ca.Ca.cert) with
  | Some (_, (true, Some 0)) -> ()
  | _ -> Alcotest.fail "root must be a CA with pathlen 0 (it signs leaves only, never sub-CAs)"

let test_leaf_validity_honours_valid_days () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  let leaf_cert, _ = Ca.sign_leaf ca ~common_name:"replica-1" ~valid_days:30 in
  let from, until = X509.Certificate.validity leaf_cert in
  let d, _ = Ptime.Span.to_d_ps (Ptime.diff until from) in
  (* [from] is backdated by a clock-skew allowance, so the window is [valid_days] plus a little. *)
  Alcotest.(check bool)
    (Printf.sprintf "leaf validity window is ~30 days (got %d)" d)
    true (d = 30)

let test_leaf_is_rejected_once_expired () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  let leaf_cert, _ = Ca.sign_leaf ca ~common_name:"replica-1" ~valid_days:1 in
  let later = shift (now ()) 3 in
  match
    X509.Validation.verify_chain_of_trust ~host:None
      ~time:(fun () -> Some later)
      ~anchors:[ ca.Ca.cert ] [ leaf_cert ]
  with
  | Ok _ -> Alcotest.fail "an expired leaf must not validate"
  | Error _ -> ()

let test_each_leaf_gets_a_fresh_key_and_a_distinct_serial () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  let c1, k1 = Ca.sign_leaf ca ~common_name:"replica-1" ~valid_days:365 in
  let c2, k2 = Ca.sign_leaf ca ~common_name:"replica-2" ~valid_days:365 in
  Alcotest.(check bool)
    "two leaves have different private keys" false
    (String.equal
       (X509.Public_key.fingerprint (X509.Private_key.public k1))
       (X509.Public_key.fingerprint (X509.Private_key.public k2)));
  Alcotest.(check bool)
    "two leaves have different serial numbers" false
    (String.equal (X509.Certificate.serial c1) (X509.Certificate.serial c2))

(* [X509.Signing_request.sign_certificate] itself refuses to issue a certificate outliving its
   issuer (verified in `signing_request.ml`). [sign_leaf] must surface that as a clear error
   rather than an opaque one, and must never return a certificate in that case. *)
let test_leaf_outliving_the_root_is_refused () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  Alcotest.check_raises "leaf outliving the root is refused"
    (Ca.Pki_error
       "signing the leaf certificate for \"replica-1\" failed: certificate is valid until a \
        later time than the issuing certificate")
    (fun () -> ignore (Ca.sign_leaf ca ~common_name:"replica-1" ~valid_days:99_999))

let test_non_positive_valid_days_is_refused () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  Alcotest.check_raises "zero valid_days is refused"
    (Ca.Pki_error "sign_leaf: valid_days must be positive, got 0")
    (fun () -> ignore (Ca.sign_leaf ca ~common_name:"replica-1" ~valid_days:0))

(* [X509.Certificate.hostnames] silently drops SAN entries that are not parseable hostnames, so
   a leaf issued for a non-DNS common name would validate against [~host:None] but fail every
   real peer-identity check with nothing to explain why. [sign_leaf] must reject it up front. *)
let test_common_name_that_is_not_a_hostname_is_refused () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  List.iter
    (fun bad ->
      match Ca.sign_leaf ca ~common_name:bad ~valid_days:365 with
      | exception Ca.Pki_error _ -> ()
      | _ -> Alcotest.failf "sign_leaf must refuse the non-hostname common name %S" bad)
    [ "replica 1"; "replica_1"; ""; "replica-1..x" ]

let tests =
  [
    ("root is a genuine self-signed CA", `Quick, test_root_is_a_genuine_self_signed_ca);
    ("root cert matches root private key", `Quick, test_root_cert_matches_root_private_key);
    ("root is a pathlen-0 CA", `Quick, test_root_is_a_pathlen_zero_ca);
    ( "sign_leaf produces a cert the root validates",
      `Quick,
      test_sign_leaf_produces_a_cert_the_root_validates );
    ("leaf signed by an unrelated CA is rejected", `Quick, test_leaf_signed_by_unrelated_ca_is_rejected);
    ("leaf is valid for its own hostname", `Quick, test_leaf_is_valid_for_its_own_hostname);
    ("leaf is rejected for a different hostname", `Quick, test_leaf_is_rejected_for_a_different_hostname);
    ("leaf is not itself a CA", `Quick, test_leaf_is_not_itself_a_ca);
    ("leaf validity honours valid_days", `Quick, test_leaf_validity_honours_valid_days);
    ("leaf is rejected once expired", `Quick, test_leaf_is_rejected_once_expired);
    ( "each leaf gets a fresh key and a distinct serial",
      `Quick,
      test_each_leaf_gets_a_fresh_key_and_a_distinct_serial );
    ("leaf outliving the root is refused", `Quick, test_leaf_outliving_the_root_is_refused);
    ("non-positive valid_days is refused", `Quick, test_non_positive_valid_days_is_refused);
    ( "a common name that is not a hostname is refused",
      `Quick,
      test_common_name_that_is_not_a_hostname_is_refused );
  ]
