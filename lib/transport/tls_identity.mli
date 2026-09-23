(** The X.509 material one replica needs in order to take part in the cluster's mutually
    authenticated TLS mesh, plus the two {!Tls.Config} values derived from it.

    {2 Why this is a separate module}

    {!Tcp} needs exactly two {!Tls.Config} values -- one for the connections it dials, one for the
    connections it accepts -- and both must be built from the same three pieces of material, with
    the same trust anchor, or the mesh is quietly asymmetric. Building them in one place, once,
    behind a constructor that validates the material first, is what makes "both ends verify each
    other" a property of this module rather than of two call sites in [tcp.ml] that happen to
    agree today.

    It also makes the configurations {e directly testable}: the transport's own test suite
    exercises the very same {!server_config} value [Tcp] installs on its listener against a
    hostile client, which is the only practical way to assert that a client presenting a bad
    certificate -- or none -- is actually rejected. Through {!Tcp}'s own public surface that
    rejection is invisible: the offending connection simply never appears in the connection table.

    {2 What this module deliberately does not do}

    It does not depend on {!Riptide_pki.Ca}, even though that is what mints every certificate the
    cluster actually uses. The values here are plain [x509] ones, so the transport layer stays
    independent of how the operator's certificates were produced (this repo's own small CA today;
    anything else later) -- the caller is what bridges the two, in one line.

    It also does not read or write files, PEM or otherwise: everything is in-memory
    {!X509.Certificate.t}/{!X509.Private_key.t} values. Certificate {e sourcing} (files, secrets
    manager, rotation) is a separate concern and is not modelled here. *)

exception Tls_config_error of string
(** Raised by {!create} when the supplied material is internally inconsistent, or when the
    underlying [tls] library rejects the configuration built from it. The message always carries
    the underlying reason verbatim, never a generic one. *)

type t
(** One replica's TLS identity: the trust anchor it authenticates {e peers} against, the
    certificate it presents to them, and the private key for that certificate -- together with the
    client and server {!Tls.Config} values derived from all three.

    Abstract on purpose: {!create}'s validation is the only way to obtain one, so a [t] that
    exists is a [t] whose certificate and private key are known to match and whose certificate is
    known to chain to its own trust anchor. *)

val create :
  trust_anchor:X509.Certificate.t ->
  cert:X509.Certificate.t ->
  priv_key:X509.Private_key.t ->
  t
(** [create ~trust_anchor ~cert ~priv_key] is the identity that presents [cert] (whose private key
    is [priv_key]) and accepts a peer only if that peer's certificate chains to [trust_anchor].

    Both {!Tls.Config} values are built eagerly, here, so that a malformed configuration fails at
    startup rather than at the first handshake -- and so that {!Tcp} builds them exactly once per
    [t] rather than once per connection.

    This also installs the process-wide RNG [tls] requires ([Mirage_crypto_rng_unix.use_default]),
    once, the first time any identity is created. [tls-eio]'s own interface documents that a
    missing RNG is a {e runtime} error raised somewhere inside a handshake; doing it here means
    the transport cannot be used at all without it having happened first. Calling
    {!Mirage_crypto_rng_unix.use_default} yourself as well is harmless.

    Two things are checked up front, because both are silent misconfigurations that would
    otherwise surface only as an opaque handshake failure against a peer:

    - [cert]'s public key must be [priv_key]'s public key. Handing over a certificate and an
      unrelated key is an easy mistake when both come from a keystore by name, and TLS's own
      symptom for it (the peer rejects our CertificateVerify signature) names neither.
    - [cert] must chain to [trust_anchor] and be valid {e now}. A replica configured with a
      certificate its own CA did not issue, or one that has already expired, cannot take part in
      the mesh at all, and finding that out at startup is strictly better than finding it out when
      the first peer refuses to talk. Note the deliberate consequence: this type cannot express a
      deployment where a replica presents a certificate from one CA while trusting another (a
      cross-signed CA rotation, say). That is not an oversight -- this repo's CA issues leaves
      directly from a single pathlen-0 root, and widening the type to fit a rotation scheme
      nothing implements yet would be policy ahead of running code.

    @raise Tls_config_error if either check fails, or if [tls] rejects the resulting configuration. *)

val client_config : t -> Tls.Config.client
(** The configuration to use when {e dialing} a peer. Its [authenticator] is always set (the [tls]
    library requires it), so the dialing side always verifies the peer's certificate against
    [trust_anchor]. *)

val server_config : t -> Tls.Config.server
(** The configuration to use when {e accepting} a connection. Its optional [?authenticator] is
    set, which is precisely what makes the mesh {e mutually} authenticated: with it unset, [tls]
    does not even send a CertificateRequest, and the accepting side would establish ordinary
    one-way TLS with any client at all, including one presenting no certificate. *)

val protocol_version : Tls.Core.tls_version * Tls.Core.tls_version
(** The exact (min, max) TLS version range both configurations above are pinned to: TLS 1.3 only.

    Both ends of every connection in this mesh run this same code against certificates from the
    same operator-run CA, so there is no interoperability argument for accepting anything older,
    and pinning removes version-downgrade negotiation from the attack surface entirely. It also
    makes the handshake's observable behaviour deterministic, which the transport's negative tests
    depend on. Exposed so a test can assert what was negotiated rather than restate the constant. *)
