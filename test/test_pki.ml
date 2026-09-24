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

(* Both CAs deliberately share a common name, so anchor-filtering by DN alone (which
   [verify_chain_of_trust]'s [issuer_matches_subject] step performs before any signature check
   runs -- traced in `validation.ml` of the `x509.1.2.0` source) cannot be what rejects this
   leaf: [ca1] is a genuine, DN-matching candidate anchor. Rejection can only come from
   [validate_signature]/[ext_authority_matches_subject] finding that the leaf was not actually
   signed by [ca1]'s key -- the cryptographic property that matters against an attacker who
   could spoof an issuer DN but not forge a signature. *)
let test_leaf_signed_by_unrelated_ca_is_rejected () =
  let ca1 = Ca.generate_root ~common_name:"riptide-test-ca" in
  let ca2 = Ca.generate_root ~common_name:"riptide-test-ca" in
  let leaf_cert, _ = Ca.sign_leaf ca2 ~common_name:"replica-x" ~valid_days:365 in
  match
    X509.Validation.verify_chain_of_trust ~host:None ~time:time_thunk ~anchors:[ ca1.Ca.cert ]
      [ leaf_cert ]
  with
  | Ok _ ->
    Alcotest.fail
      "a leaf signed by an unrelated CA's key must not validate, even against an anchor whose \
       DN happens to match the true issuer"
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

(* [x509]'s own `.mli` states plainly that [Key_usage]/[Ext_key_usage] are *not* checked by the
   library itself -- "they need to be checked by the client of the API" -- so nothing in
   [verify_chain_of_trust] or [valid_ca] would ever fail if these extensions were silently
   dropped from [sign_leaf]. Confirmed live: removing either extension from `ca.ml` does not
   fail any other test in this file. Task 8's mTLS role-checking is the actual client that will
   read them, so this test reads the minted leaf's extensions directly, the same way
   [test_leaf_is_not_itself_a_ca] and [test_root_is_a_pathlen_zero_ca] already do for
   [Basic_constraints], rather than going through the validator. *)
let test_leaf_has_the_expected_key_usage_extensions () =
  let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
  let leaf_cert, _ = Ca.sign_leaf ca ~common_name:"replica-1" ~valid_days:365 in
  let extensions = X509.Certificate.extensions leaf_cert in
  (match X509.Extension.find X509.Extension.Key_usage extensions with
   | Some (_, usages) ->
     Alcotest.(check bool)
       "leaf Key_usage contains Digital_signature" true
       (List.mem `Digital_signature usages)
   | None -> Alcotest.fail "leaf must carry an explicit Key_usage extension");
  match X509.Extension.find X509.Extension.Ext_key_usage extensions with
  | Some (_, usages) ->
    Alcotest.(check bool)
      "leaf Ext_key_usage contains Server_auth" true
      (List.mem `Server_auth usages);
    Alcotest.(check bool)
      "leaf Ext_key_usage contains Client_auth" true
      (List.mem `Client_auth usages)
  | None -> Alcotest.fail "leaf must carry an explicit Ext_key_usage extension"

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

(* ---- [Ca.save]/[Ca.load]: real PEM persistence (subtask 4.7) ----

   Closes the gap this module's own header documented as open: until now every key and
   certificate here existed only in memory, so the mesh could not cross a process boundary or
   survive a restart.

   {b On running as root.} [test_file_kv_store.ml]'s header records that this suite's environment
   runs as root, and that [CAP_DAC_OVERRIDE] therefore makes it impossible to test a failure that
   depends on the {i OS} denying access. That limitation does {i not} apply to
   [test_load_rejects_a_world_readable_key_file] below, for the same reason it does not apply to
   [Test_redaction]'s already-passing [test_kek_load_rejects_a_world_readable_file]: the check
   under test inspects the mode bits itself ([Unix.fstat], [st_perm land 0o077]) and refuses, so
   it is the {i program}, not the kernel, that rejects the file. Root reads the loose file
   perfectly well -- and [Ca.load] still raises. Confirmed live, not assumed: this test passes
   under [uid=0]. *)

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_ca_persist_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let cert_path dir = Filename.concat dir "ca-cert.pem"
let key_path dir = Filename.concat dir "ca-key.pem"

(* The round trip that actually matters. Comparing the re-encoded certificate proves the cert
   file survived intact, but says nothing about the private key -- a [Ca.t] carrying a corrupt or
   unrelated key would compare equal here. So the key is proven the only way that counts: the
   {i loaded} CA signs a fresh leaf, and that leaf is validated against the {i original},
   in-memory root as trust anchor. That can only succeed if the bytes read back off disk are
   genuinely the same signing key. *)
let test_save_load_roundtrips_and_the_loaded_ca_still_signs_valid_leaves () =
  with_tmp_dir (fun dir ->
      let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
      Ca.save ca ~dir;
      let loaded = Ca.load ~dir in
      Alcotest.(check string)
        "the loaded certificate is the certificate that was saved"
        (X509.Certificate.encode_pem ca.Ca.cert)
        (X509.Certificate.encode_pem loaded.Ca.cert);
      let leaf_cert, _leaf_key = Ca.sign_leaf loaded ~common_name:"replica-1" ~valid_days:365 in
      match
        X509.Validation.verify_chain_of_trust ~host:None ~time:time_thunk ~anchors:[ ca.Ca.cert ]
          [ leaf_cert ]
      with
      | Ok _ -> ()
      | Error e -> Alcotest.fail (Fmt.to_to_string X509.Validation.pp_validation_error e))

(* [save] must create the private-key file restrictively from the start, not chmod it down
   afterwards -- between an [open] at 0644 and a later [chmod 0600] there is a real window in
   which any local account can open the CA key and keep the descriptor. *)
let test_save_creates_the_key_file_with_no_group_or_other_access () =
  with_tmp_dir (fun dir ->
      let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
      Ca.save ca ~dir;
      let mode = (Unix.stat (key_path dir)).Unix.st_perm in
      Alcotest.(check int) "saved CA key file grants nothing to group or other" 0
        (mode land 0o077))

(* The test above only covers the {i fresh-file} case, which [Unix.openfile]'s [perm] argument
   already handled on its own. This covers the case it does not: [perm] applies only when the
   file is actually created, so overwriting a [ca-key.pem] that {i already exists} at a loose mode
   left that mode exactly as it was -- [save] would write the CA private key into a 0644 file and
   return success, with no error and no warning, and nothing in this repo calls [load] straight
   after [save] to catch it via the re-check. The exposure was silent and unbounded. The fix is
   [Unix.fchmod] on the already-open descriptor; this asserts the mode {i after} [save], not
   merely that [save] succeeded. *)
let test_save_tightens_permissions_on_a_pre_existing_loose_key_file () =
  with_tmp_dir (fun dir ->
      let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
      (* Plant a world-readable file at exactly the path [save] is about to write the key to. *)
      let oc = open_out_bin (key_path dir) in
      output_string oc "stale contents from an earlier, careless write\n";
      close_out oc;
      Unix.chmod (key_path dir) 0o644;
      Alcotest.(check int)
        "precondition: the pre-existing file really is group/other-readable" 0o044
        ((Unix.stat (key_path dir)).Unix.st_perm land 0o077);
      Ca.save ca ~dir;
      Alcotest.(check int)
        "save tightens a pre-existing loose key file to 0600 rather than inheriting its mode" 0
        ((Unix.stat (key_path dir)).Unix.st_perm land 0o077);
      (* And the tightening must not have come at the cost of the write itself. *)
      let loaded = Ca.load ~dir in
      Alcotest.(check string)
        "the key written over the loose file is still the real one"
        (X509.Certificate.encode_pem ca.Ca.cert)
        (X509.Certificate.encode_pem loaded.Ca.cert))

(* The other half of the same gap: an [O_CREAT|O_TRUNC] open {i follows symlinks}, so a
   [ca-key.pem] replaced by a symlink pointing anywhere else would deposit the CA private key at
   that target, at the target's own mode. [save] now unlinks the path first (removing the symlink
   itself, not its target) and creates with [O_EXCL]. The assertion that matters is about the
   {i target}: it must be untouched. *)
let test_save_does_not_follow_a_symlink_planted_at_the_key_path () =
  with_tmp_dir (fun dir ->
      let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
      let target = Filename.concat dir "attacker-chosen-target" in
      let sentinel = "this file must not receive the CA private key\n" in
      let oc = open_out_bin target in
      output_string oc sentinel;
      close_out oc;
      Unix.symlink target (key_path dir);
      Ca.save ca ~dir;
      let read_whole path =
        let ic = open_in_bin path in
        Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> really_input_string ic (in_channel_length ic))
      in
      Alcotest.(check string) "the symlink's target was not written through" sentinel
        (read_whole target);
      Alcotest.(check bool) "the key path is now a real file, not still a symlink" false
        ((Unix.lstat (key_path dir)).Unix.st_kind = Unix.S_LNK);
      Alcotest.(check int)
        "and that real file is 0600" 0
        ((Unix.stat (key_path dir)).Unix.st_perm land 0o077))

(* Mirrors [test_load_of_a_missing_directory_raises_sys_error] below, for [save]'s own side --
   and deliberately asserts a {i different} exception, because that is what [save] genuinely
   raises. [load] opens with [open_in_bin] (stdlib, [Sys_error]); [save] opens with
   [Unix.openfile] ([Unix.Unix_error]). [ca.mli] documented [Sys_error] for both, which was
   simply wrong for [save]: a caller following that contract would have caught nothing. This
   test is what stops the documented contract drifting away from the real one again. *)
let test_save_into_a_missing_directory_raises_unix_error () =
  with_tmp_dir (fun dir ->
      let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
      let absent = Filename.concat dir "not-created" in
      match Ca.save ca ~dir:absent with
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
      | exception e ->
        Alcotest.failf "saving into a missing directory must raise Unix_error (ENOENT, _, _), got %s"
          (Printexc.to_string e)
      | () -> Alcotest.fail "saving into a missing directory must not succeed")

(* Mirrors [Test_redaction.test_kek_load_rejects_a_world_readable_file] exactly, one layer up: a
   CA private key readable by group or other is not a secret, and a compromised CA key is
   strictly worse than any leaf's -- it mints arbitrary trusted identities for the whole
   cluster. *)
let test_load_rejects_a_world_readable_key_file () =
  with_tmp_dir (fun dir ->
      let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
      Ca.save ca ~dir;
      Unix.chmod (key_path dir) 0o644;
      Alcotest.check_raises "a group/other-readable CA key file is rejected on load"
        (Invalid_argument
           (Printf.sprintf
              "Ca.load: %s has mode 0644, which grants access to group or other; a CA private key \
               file must be 0600 or stricter"
              (key_path dir)))
        (fun () -> ignore (Ca.load ~dir)))

(* [generate_root]/[sign_leaf] guarantee by construction that a [Ca.t]'s key and certificate
   belong together; nothing guarantees that for two files an operator put in a directory. The
   shape this catches is mundane and real -- a half-finished restore, or a backup that mixed two
   generations of root -- and the consequence of not catching it is a CA that loads cleanly and
   then fails at every signing attempt, far from the cause. *)
let test_load_rejects_a_key_that_does_not_match_the_certificate () =
  with_tmp_dir (fun dir ->
      let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
      let unrelated = Ca.generate_root ~common_name:"riptide-test-ca" in
      Ca.save ca ~dir;
      (* Overwrite only the key file, leaving [ca]'s certificate in place. O_TRUNC on the
         existing 0600 file leaves its mode alone, so this isolates the mismatch from the
         permission check above. *)
      let fd = Unix.openfile (key_path dir) [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let oc = Unix.out_channel_of_descr fd in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc (X509.Private_key.encode_pem unrelated.Ca.key));
      Alcotest.check_raises "a key that is not the certificate's key is rejected on load"
        (Failure
           (Printf.sprintf "Ca.load: %s: private key does not match certificate %s" (key_path dir)
              (cert_path dir)))
        (fun () -> ignore (Ca.load ~dir)))

let test_load_of_a_malformed_pem_fails_loudly () =
  with_tmp_dir (fun dir ->
      let ca = Ca.generate_root ~common_name:"riptide-test-ca" in
      Ca.save ca ~dir;
      let oc = open_out_bin (cert_path dir) in
      output_string oc "-----BEGIN CERTIFICATE-----\nnot base64 at all\n-----END CERTIFICATE-----\n";
      close_out oc;
      match Ca.load ~dir with
      | exception Failure _ -> ()
      | exception e ->
        Alcotest.failf "a malformed certificate PEM must raise Failure, got %s"
          (Printexc.to_string e)
      | _ -> Alcotest.fail "a malformed certificate PEM must not load")

let test_load_of_a_missing_directory_raises_sys_error () =
  with_tmp_dir (fun dir ->
      let absent = Filename.concat dir "not-created" in
      match Ca.load ~dir:absent with
      | exception Sys_error _ -> ()
      | exception e ->
        Alcotest.failf "loading from a missing directory must raise Sys_error, got %s"
          (Printexc.to_string e)
      | _ -> Alcotest.fail "loading from a missing directory must not succeed")

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
    ( "leaf has the expected Key_usage/Ext_key_usage extensions",
      `Quick,
      test_leaf_has_the_expected_key_usage_extensions );
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
    ( "save/load round-trips and the loaded CA still signs valid leaves",
      `Quick,
      test_save_load_roundtrips_and_the_loaded_ca_still_signs_valid_leaves );
    ( "save creates the key file with no group or other access",
      `Quick,
      test_save_creates_the_key_file_with_no_group_or_other_access );
    ( "save tightens permissions on a pre-existing loose key file",
      `Quick,
      test_save_tightens_permissions_on_a_pre_existing_loose_key_file );
    ( "save does not follow a symlink planted at the key path",
      `Quick,
      test_save_does_not_follow_a_symlink_planted_at_the_key_path );
    ( "save into a missing directory raises Unix_error",
      `Quick,
      test_save_into_a_missing_directory_raises_unix_error );
    ( "load rejects a world-readable key file",
      `Quick,
      test_load_rejects_a_world_readable_key_file );
    ( "load rejects a key that does not match the certificate",
      `Quick,
      test_load_rejects_a_key_that_does_not_match_the_certificate );
    ("load of a malformed PEM fails loudly", `Quick, test_load_of_a_malformed_pem_fails_loudly);
    ( "load of a missing directory raises Sys_error",
      `Quick,
      test_load_of_a_missing_directory_raises_sys_error );
  ]
