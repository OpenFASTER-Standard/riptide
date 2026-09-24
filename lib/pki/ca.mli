(** A minimal, real, self-managed PKI: a self-signed Ed25519 root CA plus leaf-certificate
    issuance for cluster replicas. See [ca.ml]'s header for the design rationale and for the
    record of which [x509] APIs were verified against the real library.

    {2 Open gap: there is no persistence story for this material}

    Stated plainly rather than assumed away (final-review finding, 2026-09-23). Everything this
    module produces -- the root CA's own private key and certificate, and every leaf keypair and
    certificate [sign_leaf] mints -- exists only as in-memory [X509.Private_key.t] /
    [X509.Certificate.t] values, for the lifetime of the process that called [generate_root].
    There is no PEM (or DER, or any other) encode/decode anywhere in this module, nothing writes
    any of it to disk or to a secrets manager, and nothing loads it back.

    The direct consequence: the PKI + mTLS mesh this composes with
    ([Riptide_transport.Tls_identity], [Riptide_transport.Tcp]) cannot currently span two
    separate OS processes, and cannot survive a restart. Every participant that is to trust the
    same root has to be handed that root's [t] value in-memory, which in practice means
    being in the same process -- which is exactly the shape of this repo's own transport tests,
    the only callers that exist today. A real deployment would instead generate the root once,
    persist it, and have each replica load its own long-lived leaf at startup.

    This is in tension with the design spec's Decision 6 framing that "certs are static and
    long-lived": that framing presupposes persistence, and persistence is not built. It is a real,
    currently-open gap, not a deliberate design position, and it is only tolerable at this stage
    because no replica server binary exists in this repo yet for it to block. {b Tracked as future
    work}: certificate/key serialisation and sourcing (PEM encode/decode, on-disk or
    secrets-manager loading, and whatever validation that needs) is its own task, deliberately not
    smuggled into the task that built the CA itself.

    See [Riptide_transport.Tls_identity]'s own header for the same gap stated from the consuming
    side. *)

(** Raised by every function here when certificate generation or signing cannot succeed. The
    message always carries the underlying [x509] error, never a generic one. *)
exception Pki_error of string

(** A certificate authority: its private key and its own certificate.

    Deliberately a plain, exposed record rather than an abstract type -- Task 8's mTLS wiring
    needs [ca.cert] directly, as the trust anchor it hands to [X509.Authenticator]. *)
type t = { key : X509.Private_key.t; cert : X509.Certificate.t }

(** [generate_root ~common_name] is a fresh, self-signed root CA valid for ten years: a new
    Ed25519 private key and a matching certificate whose subject and issuer are both
    [common_name].

    The certificate is a pathlen-0 CA (BasicConstraints CA:true critical, KeyUsage
    keyCertSign+cRLSign critical), so it may sign end-entity certificates only, never a
    sub-CA. Its notBefore is backdated by a small clock-skew allowance.

    @raise Pki_error if key generation or self-signing fails. *)
val generate_root : common_name:string -> t

(** [sign_leaf ca ~common_name ~valid_days] is a fresh Ed25519 keypair plus an end-entity
    certificate for [common_name], signed by [ca] and valid for [valid_days] days.

    The certificate is explicitly not a CA (BasicConstraints CA:false critical), carries
    [common_name] as a DNS SubjectAltName -- which is what [X509.Certificate.hostnames], and
    therefore peer-identity checking, actually reads -- and is usable for both ends of an mTLS
    connection (ExtendedKeyUsage serverAuth+clientAuth, KeyUsage digitalSignature).

    [common_name] must be a valid, non-empty DNS hostname, because it is what goes into the SAN:
    [X509.Certificate.hostnames] silently drops SAN entries it cannot parse, so anything else
    would yield a certificate that matches no peer, with nothing in it to say why.

    @raise Pki_error
      if [valid_days] is not positive, if [common_name] is not a valid hostname, or if signing
      fails -- in particular if [valid_days] would take the leaf past the root's own expiry,
      which the underlying library refuses. *)
val sign_leaf : t -> common_name:string -> valid_days:int -> X509.Certificate.t * X509.Private_key.t
