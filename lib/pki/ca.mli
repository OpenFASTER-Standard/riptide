(** A minimal, real, self-managed PKI: a self-signed Ed25519 root CA plus leaf-certificate
    issuance for cluster replicas. See [ca.ml]'s header for the design rationale and for the
    record of which [x509] APIs were verified against the real library.

    {2 Persistence: the root, and only the root}

    {!save} and {!load} are real PEM persistence for the root CA's own key and certificate
    (subtask 4.7), closing what this header previously recorded as an open gap: the root can now
    be generated once, written to a directory, and loaded back by a later process, so a cluster's
    trust anchor survives a restart and can be shared across separate OS processes rather than
    only in-memory within one.

    {b What is still not persisted: leaf material.} {!sign_leaf} returns an in-memory
    [X509.Certificate.t * X509.Private_key.t] and nothing here writes it anywhere. That is a
    deliberate boundary, not an oversight -- where a given replica's own long-lived leaf comes
    from (minted at startup from a loaded root, delivered by an orchestrator, fetched from a
    secrets manager) is a deployment question, and no replica server binary exists in this repo
    yet to answer it. A caller that wants leaf material on disk can encode it with the same
    [X509.Certificate.encode_pem]/[X509.Private_key.encode_pem] this module uses, but must supply
    its own permission discipline for the key; {!save} does that only for the CA's.

    {b No non-test caller yet.} This is a library capability. Nothing in this repo calls {!save}
    or {!load} outside [test/test_pki.ml]; the transport layer
    ([Riptide_transport.Tls_identity]) still takes plain in-memory [x509] values and deliberately
    does not depend on this module. See that module's own header for the boundary from the
    consuming side. *)

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

(** [save ca ~dir] writes [ca] to two PEM files in the existing directory [dir]:
    [ca-cert.pem] (the certificate) and [ca-key.pem] (the private key). Both are truncated and
    overwritten if they already exist.

    [ca-key.pem] is created with mode [0600] at open time, not chmod-ed down afterwards: between
    a default-mode create and a later tightening there is a real window in which another local
    account can open the CA private key and keep the descriptor. Note that this applies to
    {e creation} -- overwriting a file that already exists with looser permissions leaves those
    permissions as they were, which is one reason {!load} re-checks rather than trusting what
    [save] wrote.

    Both files, and the directory entries naming them, are [fsync]-ed before this returns: a root
    CA is written once and relied on indefinitely, and a crash that lost it would take every
    certificate in the cluster with it. This mirrors the durability discipline
    [Riptide_storage.File_storage] applies to the write-ahead log (O_DSYNC), rather than trusting
    the page cache.

    [dir] must already exist; this function does not create it.

    @raise Sys_error
      if [dir] does not exist, or either file cannot be created, written or synced (propagated
      verbatim from the underlying [open]/[write]/[fsync]). *)
val save : t -> dir:string -> unit

(** [load ~dir] is the CA previously written to [dir] by {!save}, read back from
    [dir/ca-cert.pem] and [dir/ca-key.pem].

    [ca-key.pem] must grant no access to group or other -- mode [0600] or stricter. This is
    checked with [Unix.fstat] on the already-open descriptor rather than [Unix.stat] on the path,
    so the file cannot be swapped between the check and the read, mirroring
    [Riptide_crypto.Kek.load]'s own discipline for on-disk key material.

    The loaded key and certificate are additionally verified to belong together (by public-key
    fingerprint), an invariant {!generate_root} and {!sign_leaf} guarantee by construction for an
    in-memory [t] but which two files in a directory do not.

    @raise Sys_error if [dir] or either file is missing or unreadable.
    @raise Invalid_argument
      if [ca-key.pem] is readable, writable or executable by group or other. The message names
      the path and the offending mode.
    @raise Failure
      if either file is not decodable as the PEM it should be, or if the private key is not the
      certificate's key.

    Note that these are deliberately {i not} {!Pki_error}: they mirror the exception convention
    [Riptide_crypto.Kek.load] already established in this repo for loading key material off
    disk. {!Pki_error} remains what the generation and signing functions above raise. *)
val load : dir:string -> t
