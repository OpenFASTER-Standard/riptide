(* A minimal, real, self-managed PKI: a self-signed Ed25519 root CA that issues short-lived
   Ed25519 leaf certificates for cluster replicas. Task 8 wires these into real mTLS via
   [tls-eio]; nothing here is a placeholder or a stub.

   {b API verification.} Following the precedent at the top of [lib/storage/file_storage.ml],
   every [x509] call below was checked against the real installed library
   (`x509` 1.2.0 at `/work/toolchain/opam-root/5.0.0/lib/x509/x509.mli`) rather than assumed,
   and -- where the library's acceptance rules, not just its types, decide whether the
   certificates we mint actually validate -- against the library's own implementation
   (`lib/validation.ml` and `lib/signing_request.ml` of the `x509.1.2.0` source, fetched with
   `opam source x509.1.2.0`). Findings, because three of them contradicted the plan:

   - [X509.Signing_request.sign_certificate] {i does} exist, with exactly the shape the plan
     assumed: [t -> valid_from:Ptime.t -> valid_until:Ptime.t -> ?allowed_hashes -> ?digest ->
     ?serial -> ?extensions -> ?subject -> Private_key.t -> Certificate.t ->
     (Certificate.t, Validation.signature_error) result]. It is the right function for signing
     under an existing CA: it takes the issuer's {i certificate} (not a bare DN), derives the
     issuer DN from it, and additionally enforces two things plain [sign] does not -- that the
     supplied private key actually matches the issuer certificate's public key, and that the
     leaf's validity window lies inside the issuer's.
   - [X509.Validation.verify_chain_of_trust] takes [~time:(unit -> Ptime.t option)] -- a thunk
     returning an option -- and [~host] is a {i required} labelled argument. The plan's test
     passed a bare [Ptime.t] and omitted [~host] entirely; neither typechecks.
   - Its error type is [validation_error], so [pp_validation_error] prints it, not the
     [pp_chain_error] the plan's test used (a different, non-unifiable type).

   {b Why these extensions, and not fewer.} A certificate with no X.509v3 extensions does not
   validate as a CA at all: [Validation.validate_ca_extensions] requires BasicConstraints
   present with CA true {i and} KeyUsage present containing [`Key_cert_sign], and rejects any
   other extension marked critical. The plan's sketch emitted no extensions, so its root would
   have failed [valid_ca] and its leaves would have failed [verify_chain_of_trust] with
   [`NoTrustAnchor]. Beyond merely satisfying the validator:

   - {b pathlen 0} on the root means the root may sign only end-entity certificates, never a
     sub-CA. [Validation.validate_path_len] enforces it, so a stolen leaf key can never be
     parlayed into an intermediate that the cluster would trust.
   - {b BasicConstraints CA:false, critical} on leaves is the same property from the other
     side: a compromised replica cannot mint certificates for its peers.
   - {b SubjectAltName (DNS)} is what actually names a replica. [X509.Certificate.hostnames]
     reads DNS SAN entries only -- a CommonName is {i not} consulted -- so without this, Task
     8's peer-identity check could not distinguish one replica from another.
   - {b ExtendedKeyUsage serverAuth + clientAuth} on leaves because in mTLS every replica is
     both. Deliberately absent from the root: [validate_ca_extensions] additionally demands
     that a CA carrying EKU include [`Any] or [`Server_auth], and a root CA has no business
     claiming either.
   - {b KeyUsage digitalSignature} only on leaves. Not [`Key_encipherment], which would be
     meaningless for an EdDSA key (Ed25519 signs; it does not encipher).
   - {b SubjectKeyId / AuthorityKeyId} let a verifier link leaf to issuer by key rather than by
     name alone; [Validation.ext_authority_matches_subject] checks they agree when both are
     present, so they are set consistently from [X509.Public_key.id].

   {b Clock skew.} Certificates are backdated by {!skew_allowance}. [Validation.validate_time]
   requires [now] to be {i strictly} later than notBefore, so a certificate minted at [t] and
   used at [t] would otherwise be rejected outright; and replicas' clocks differ in any case.
   The root is backdated too, which also keeps it consistent with
   [sign_certificate]'s requirement that a leaf's window lie inside its issuer's. *)

exception Pki_error of string

let () =
  Printexc.register_printer (function
    | Pki_error m -> Some (Printf.sprintf "Riptide_pki.Ca.Pki_error(%s)" m)
    | _ -> None)

let fail fmt = Printf.ksprintf (fun m -> raise (Pki_error m)) fmt

type t = { key : X509.Private_key.t; cert : X509.Certificate.t }

(* Ed25519: modern, fast, small, and no RSA bit-size decision to make. Verified present in
   [X509.Key_type.t] = [ `RSA | `ED25519 | `P256 | `P384 | `P521 ]. *)
let key_type = `ED25519

(* Ten years. The root is the cluster's trust anchor; rotating it is an operational event, not
   a routine one, and [sign_certificate] refuses to issue any leaf outliving it. *)
let root_valid_days = 3650

(* Five minutes, in both directions in effect: notBefore is backdated by this much. *)
let skew_allowance = Ptime.Span.of_int_s 300

(* Not written with a [X509.Distinguished_name.[...]] local open: that open also brings
   [Distinguished_name.common_name : t -> Common_name.t option] into scope, which shadows this
   function's own [~common_name] parameter. *)
let dn ~common_name =
  let module Dn = X509.Distinguished_name in
  [ Dn.Relative_distinguished_name.singleton (Dn.CN (Dn.Common_name.v common_name)) ]

let days d =
  match Ptime.Span.of_d_ps (d, 0L) with
  | Some s -> s
  | None -> fail "internal: %d is not a representable day span" d

let add_span what t span =
  match Ptime.add_span t span with
  | Some t -> t
  | None -> fail "internal: %s overflows the representable time range" what

let sub_span what t span =
  match Ptime.sub_span t span with
  | Some t -> t
  | None -> fail "internal: %s underflows the representable time range" what

let key_id key = X509.Public_key.id (X509.Private_key.public key)

let csr ~subject ~key ~what =
  match X509.Signing_request.create subject key with
  | Ok csr -> csr
  | Error (`Msg m) -> fail "building the %s signing request failed: %s" what m

let generate_root ~common_name =
  let key = X509.Private_key.generate key_type in
  let subject = dn ~common_name in
  let now = Ptime_clock.now () in
  let valid_from = sub_span "the root CA's notBefore" now skew_allowance in
  let valid_until = add_span "the root CA's notAfter" now (days root_valid_days) in
  let extensions =
    let open X509.Extension in
    empty
    (* Critical: a relying party that cannot understand "this is a CA, pathlen 0" must refuse
       the certificate rather than ignore the constraint. *)
    |> add Basic_constraints (true, (true, Some 0))
    |> add Key_usage (true, [ `Key_cert_sign; `CRL_sign ])
    |> add Subject_key_id (false, key_id key)
  in
  let csr = csr ~subject ~key ~what:"root CA" in
  (* Self-signed: the issuer DN passed here is the root's own subject. *)
  match X509.Signing_request.sign csr ~valid_from ~valid_until ~extensions key subject with
  | Ok cert -> { key; cert }
  | Error e ->
    fail "self-signing the root CA certificate failed: %s"
      (Fmt.to_to_string X509.Validation.pp_signature_error e)

(* [X509.Certificate.hostnames] parses DNS SAN entries with [Domain_name.of_string] followed by
   [Domain_name.host], and silently drops any entry that fails either. A leaf whose common name
   is not a valid hostname would therefore be minted happily and then fail every peer-identity
   check at connection time, with nothing in the certificate to explain why. Rejecting it here
   turns that silent, far-away failure into a loud, immediate one. *)
let check_hostname common_name =
  match Domain_name.of_string common_name with
  | Error (`Msg m) -> fail "sign_leaf: %S is not a valid DNS name: %s" common_name m
  | Ok d -> (
    match Domain_name.host d with
    | Error (`Msg m) -> fail "sign_leaf: %S is not a valid hostname: %s" common_name m
    (* [Domain_name.of_string ""] is the DNS root, which [host] accepts (it has no labels, so
       every label is trivially valid) -- caught by the test for this function, not predicted.
       An empty SAN names nothing and would match no peer. *)
    | Ok h when Domain_name.count_labels h = 0 ->
      fail "sign_leaf: the common name must not be empty"
    | Ok _ -> ())

let sign_leaf t ~common_name ~valid_days =
  if valid_days <= 0 then fail "sign_leaf: valid_days must be positive, got %d" valid_days;
  check_hostname common_name;
  let leaf_key = X509.Private_key.generate key_type in
  let subject = dn ~common_name in
  let now = Ptime_clock.now () in
  let valid_from = sub_span "the leaf certificate's notBefore" now skew_allowance in
  let valid_until = add_span "the leaf certificate's notAfter" now (days valid_days) in
  let extensions =
    let open X509.Extension in
    empty
    |> add Basic_constraints (true, (false, None))
    |> add Key_usage (true, [ `Digital_signature ])
    |> add Ext_key_usage (false, [ `Server_auth; `Client_auth ])
    |> add Subject_alt_name (false, X509.General_name.singleton DNS [ common_name ])
    |> add Authority_key_id (false, (Some (key_id t.key), X509.General_name.empty, None))
    |> add Subject_key_id (false, key_id leaf_key)
  in
  let csr = csr ~subject ~key:leaf_key ~what:"leaf certificate" in
  (* [sign_certificate] (not [sign]) because the issuer is an existing certificate: it derives
     the issuer DN from [t.cert], checks [t.key] really is that certificate's key, and refuses
     a validity window wider than the root's own. *)
  match
    X509.Signing_request.sign_certificate csr ~valid_from ~valid_until ~extensions t.key t.cert
  with
  | Ok cert -> (cert, leaf_key)
  | Error e ->
    fail "signing the leaf certificate for %S failed: %s" common_name
      (Fmt.to_to_string X509.Validation.pp_signature_error e)
