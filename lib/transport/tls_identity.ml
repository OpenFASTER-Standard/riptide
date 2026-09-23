(* See tls_identity.mli for what this module is for and why the two configurations are built here
   rather than at [Tcp]'s call sites. *)

exception Tls_config_error of string

let fail fmt = Printf.ksprintf (fun s -> raise (Tls_config_error s)) fmt

(* TLS 1.3 only -- see the [protocol_version] doc comment in the .mli for why. *)
let protocol_version : Tls.Core.tls_version * Tls.Core.tls_version = (`TLS_1_3, `TLS_1_3)

(* [tls] raises at runtime if no RNG has been installed, from somewhere deep inside a handshake.
   Forced once, from [create], so that the transport is unusable without it having happened first
   rather than failing on the first connection. [lazy] rather than a bare top-level side effect so
   that merely linking this library does not reconfigure a process's RNG. *)
let rng_installed = lazy (Mirage_crypto_rng_unix.use_default ())

type t = {
  client_config : Tls.Config.client;
  server_config : Tls.Config.server;
}

let now () = Some (Ptime_clock.now ())

(* [cert] and [priv_key] must be a pair. Compared by public-key fingerprint rather than structural
   equality so this does not depend on how [x509] happens to represent a given key type. *)
let check_key_matches_cert ~cert ~priv_key =
  let of_cert = X509.Public_key.fingerprint (X509.Certificate.public_key cert) in
  let of_key = X509.Public_key.fingerprint (X509.Private_key.public priv_key) in
  if not (String.equal of_cert of_key) then
    fail
      "Tls_identity.create: the supplied private key does not match the supplied certificate (the \
       certificate's public key and the private key's public key have different fingerprints)"

(* [cert] must be a currently-valid end-entity certificate issued by [trust_anchor]. This is the
   same check, through the same code path, that this identity's own [authenticator] will apply to
   every peer -- run once against ourselves, at startup. [~host:None] because a replica's own
   certificate is not being matched against any particular name here; name matching is a peer-side
   question. *)
let check_cert_chains_to_anchor ~trust_anchor ~cert =
  match
    X509.Validation.verify_chain_of_trust ~host:None ~time:now ~anchors:[ trust_anchor ] [ cert ]
  with
  | Ok _ -> ()
  | Error err ->
    fail "Tls_identity.create: this replica's own certificate does not chain to its trust anchor: %s"
      (Fmt.to_to_string X509.Validation.pp_validation_error err)

let create ~trust_anchor ~cert ~priv_key =
  Lazy.force rng_installed;
  check_key_matches_cert ~cert ~priv_key;
  check_cert_chains_to_anchor ~trust_anchor ~cert;
  let authenticator = X509.Authenticator.chain_of_trust ~time:now [ trust_anchor ] in
  let certificates = `Single ([ cert ], priv_key) in
  let client_config =
    (* [authenticator] is a *required* argument here: a client always verifies its peer. *)
    match Tls.Config.client ~authenticator ~certificates ~version:protocol_version () with
    | Ok c -> c
    | Error (`Msg m) -> fail "Tls_identity.create: invalid TLS client configuration: %s" m
  in
  let server_config =
    (* [?authenticator] is OPTIONAL here, and passing it is the entire difference between one-way
       TLS and mutual TLS: with it unset, [tls] does not send a CertificateRequest at all and this
       side accepts any client, including one with no certificate. See
       [test_transport_tcp.ml]'s two "server rejects ..." cases, which fail if this is dropped. *)
    match
      Tls.Config.server ~authenticator ~certificates ~version:protocol_version ()
    with
    | Ok c -> c
    | Error (`Msg m) -> fail "Tls_identity.create: invalid TLS server configuration: %s" m
  in
  { client_config; server_config }

let client_config t = t.client_config
let server_config t = t.server_config
