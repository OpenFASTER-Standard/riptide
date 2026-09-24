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

(* ---- Persistence (subtask 4.7) ----------------------------------------------------------

   Closes the "no persistence story" gap this file's own header and [ca.mli] documented as open:
   until now the root's key and certificate lived only in the process that called
   [generate_root], so the mesh could not cross a process boundary or survive a restart.

   {b API verification.} Same discipline as the rest of this file. All four calls used below
   were re-checked against the real installed library before use, not assumed:
   [X509.Private_key.encode_pem : t -> string] and
   [X509.Private_key.decode_pem : string -> (t, [> `Msg of string]) result]
   (`x509.mli` lines 234-239), and [X509.Certificate.encode_pem]/[decode_pem] with the same
   shapes (lines 641-649). [Certificate.decode_pem] -- singular -- is the right one here: a CA
   directory holds exactly one root certificate, and [decode_pem_multiple] would silently accept
   a file containing several, leaving which one is the trust anchor ambiguous.

   {b Exception discipline.} Unlike the generation/signing functions above, which raise
   {!Pki_error}, [save] and [load] below mirror {!Riptide_crypto.Kek.load}'s already-established
   convention for loading key material off disk -- [Sys_error] for an absent/unopenable file
   (propagated from [open_in_bin], deliberately: a process that cannot load its CA must fail to
   start rather than continue with anything else), [Invalid_argument] for unsafe permissions, and
   [Failure] for content that is present and readable but not what it claims to be. That
   convention is what this repo's other on-disk secret loader already raises, and [ca.mli]
   documents it per function.

   The one asymmetry, documented as such in [ca.mli] rather than papered over: [save] reaches the
   filesystem through [Unix.openfile]/[Unix.fchmod]/[Unix.fsync], which raise [Unix.Unix_error],
   {i not} [Sys_error] -- so a missing [dir] fails [save] with [Unix_error (ENOENT, "open", _)]
   while it fails [load] with [Sys_error]. Both are propagated verbatim; neither is translated
   into the other, because rewrapping would discard the errno a caller diagnosing a real
   deployment problem actually needs. *)

let cert_filename = "ca-cert.pem"
let key_filename = "ca-key.pem"

(* Written through an explicit descriptor with an explicit [perm], and flushed all the way to
   the device before the descriptor is closed.

   [perm] rather than [open_out_bin]'s umask default because the key file must be 0600 from the
   moment it exists: [open] at the default (commonly 0644) followed by a [Unix.chmod] leaves a
   real window in which any local account can open the CA private key and hold the descriptor
   open past the chmod.

   {b Why unlink-then-O_EXCL rather than O_CREAT|O_TRUNC.} [openfile]'s [perm] argument applies
   only when the file is actually {i created}. An earlier version of this function opened with
   O_CREAT|O_TRUNC, which meant that overwriting a {i pre-existing} [ca-key.pem] left whatever
   mode it already had untouched: a file sitting at 0644 would silently receive the CA private
   key and stay 0644, with no error and no warning. Worse, an O_CREAT|O_TRUNC open {i follows
   symlinks}, so a [ca-key.pem] that had been replaced with a symlink to an attacker-chosen path
   would deposit the key at that target, at the target's own mode. Unlinking first (ignoring
   ENOENT) removes the symlink itself rather than its target, and O_EXCL then refuses to create
   through any symlink raced back in between the two calls -- the open fails with EEXIST instead
   of writing the secret somewhere else.

   {b And why [fchmod] on top of that.} O_EXCL guarantees a fresh file, but [perm] is still
   subject to the process umask, so [perm] alone does not {i guarantee} the resulting mode.
   [Unix.fchmod fd perm] immediately after the open settles it unconditionally, and does so on
   the descriptor this function already holds rather than on the path -- the same
   fstat-on-descriptor discipline [check_key_permissions] below uses, so there is no window in
   which the path could be swapped for something else and chmod-ed instead. It runs before any
   content is written, so the key bytes never exist on disk under a wider mode than the final one.

   [load] still re-checks permissions rather than trusting any of this: the file can be chmod-ed
   by anything at all in the arbitrarily long interval between [save] and a later [load], so what
   [save] guarantees at write time is not what a reader needs to know at read time.

   Note that this is deliberately {i not} an atomic replacement -- there is a window after the
   unlink in which no CA file exists, exactly as there was a window after the O_TRUNC in which a
   truncated one did. Making the overwrite atomic (write to a temporary name, fsync, rename)
   is a real improvement but a larger change than this one, and is tracked separately.

   The [fsync] is this repo's existing durability discipline applied here: [file_storage.ml]
   opens its WAL with O_DSYNC precisely so an acknowledged write is on the device and not just in
   the page cache. A root CA is if anything less forgiving -- it is written once and then relied
   on indefinitely, and a crash between [save] returning and the kernel flushing would lose the
   trust anchor every certificate in the cluster chains to, with no way to reconstruct it. *)
let write_file_durably ~path ~perm contents =
  (try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] perm in
  let oc = Unix.out_channel_of_descr fd in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      Unix.fchmod fd perm;
      output_string oc contents;
      flush oc;
      Unix.fsync fd)

let save t ~dir =
  write_file_durably
    ~path:(Filename.concat dir cert_filename)
    ~perm:0o644
    (X509.Certificate.encode_pem t.cert);
  write_file_durably
    ~path:(Filename.concat dir key_filename)
    ~perm:0o600
    (X509.Private_key.encode_pem t.key);
  (* Fsyncing the files is not enough on its own: on a crash the directory entries themselves
     can be missing, leaving a durable file nothing names. Opening the directory read-only and
     fsyncing it is the standard way to make the two [creat]s above durable too. *)
  let dfd = Unix.openfile dir [ Unix.O_RDONLY ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close dfd) (fun () -> Unix.fsync dfd)

(* Mirrors [Riptide_crypto.Kek.check_permissions] (lib/crypto/kek.ml) exactly, including its
   reasoning: checked via the already-open descriptor ([Unix.fstat]), never the path
   ([Unix.stat]), so nothing can swap the file between the check and the read. 0o077 is every
   group and other bit. The stake is strictly higher here than for a KEK: a leaked CA private key
   mints arbitrary certificates every replica in the cluster will trust. *)
let check_key_permissions ~path fd =
  let st = Unix.fstat fd in
  if st.Unix.st_perm land 0o077 <> 0 then
    invalid_arg
      (Printf.sprintf
         "Ca.load: %s has mode %04o, which grants access to group or other; a CA private key file \
          must be 0600 or stricter"
         path st.Unix.st_perm)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let read_key_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      check_key_permissions ~path (Unix.descr_of_in_channel ic);
      really_input_string ic (in_channel_length ic))

(* Deliberately a local four-line duplicate of {!Riptide_transport.Tls_identity}'s
   [check_key_matches_cert], not a call to it.

   Calling it would compile today -- checked, rather than assumed from the plan, which asserted a
   dependency cycle: [lib/transport/dune] does {i not} list [riptide_pki], and
   [tls_identity.mli] states the non-dependency as a deliberate design property ("It does not
   depend on {!Riptide_pki.Ca} ... so the transport layer stays independent of how the operator's
   certificates were produced"). There is therefore no cycle to break. It is still the wrong
   thing to do, for three reasons that outlive the cycle question:

   - It inverts the layering. [riptide_pki] is the lower library; depending on [riptide_transport]
     would drag [eio], [tls], [tls-eio] and [mirage-crypto-rng.unix] into every consumer of the
     CA, to reuse one fingerprint comparison.
   - It would turn the natural {i future} direction -- transport, or a replica binary, depending
     on pki -- into a genuine cycle. Today's absence of one is a reason to keep the arrow
     pointing the way it already does, not a licence to add the opposite arrow.
   - Its failure is a [Tls_config_error] whose message is hardcoded to say
     "Tls_identity.create: ...", which is simply untrue when the caller is [Ca.load].

   So the {i logic} is mirrored, not the name: compare the certificate's public key and the
   private key's derived public key by [X509.Public_key.fingerprint], rather than by structural
   equality, so this does not depend on how [x509] happens to represent a given key type. *)
let check_key_matches_cert ~cert_path ~key_path ~cert ~key =
  let of_cert = X509.Public_key.fingerprint (X509.Certificate.public_key cert) in
  let of_key = X509.Public_key.fingerprint (X509.Private_key.public key) in
  if not (String.equal of_cert of_key) then
    failwith
      (Printf.sprintf "Ca.load: %s: private key does not match certificate %s" key_path cert_path)

let load ~dir =
  let cert_path = Filename.concat dir cert_filename in
  let cert =
    match X509.Certificate.decode_pem (read_file cert_path) with
    | Ok cert -> cert
    | Error (`Msg m) -> failwith (Printf.sprintf "Ca.load: %s: %s" cert_path m)
  in
  let key_path = Filename.concat dir key_filename in
  let key =
    match X509.Private_key.decode_pem (read_key_file key_path) with
    | Ok key -> key
    | Error (`Msg m) -> failwith (Printf.sprintf "Ca.load: %s: %s" key_path m)
  in
  (* [generate_root] and [sign_leaf] guarantee by construction that a [t]'s key and certificate
     belong together. Two files in a directory guarantee nothing, so the invariant is re-checked
     on the way back in -- otherwise a mixed-up restore yields a [t] that loads cleanly and then
     fails at every [sign_leaf], far from the cause. *)
  check_key_matches_cert ~cert_path ~key_path ~cert ~key;
  { key; cert }
