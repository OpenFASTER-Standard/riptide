(** A single, unwrapped Data Encryption Key (DEK) for envelope encryption (design spec
    Decision 4): AES-256-GCM keyed material plus its own private nonce state, used to encrypt
    and decrypt individual payloads.

    {b Envelope encryption, and where {!t} sits in it.} Per Decision 4, every redactable payload
    gets a fresh, independently-generated DEK -- never one derived from the Key Encryption Key
    (KEK) via HKDF or similar, because a derived key can't be individually forgotten without
    erasing everything else derived from the same KEK. A {!t} is the *unwrapped* half of that
    design: the raw key material as used to actually encrypt/decrypt payloads. The *wrapped*
    half -- this DEK's {!raw} bytes themselves encrypted under the KEK for long-term storage in
    Task 6's keystore -- is deliberately out of scope here; {!raw} and {!of_raw} exist
    specifically to hand those bytes to and from that wrapping/unwrapping step.

    {b Deterministic counter nonce, not a random one.} Per NIST SP 800-38D §8.2.1's "Deterministic
    Construction" and matching Kubernetes KMS v2's shipped approach, each {!t}'s 96-bit GCM nonce
    is a fixed 4-byte random prefix (chosen once, at construction, so two different {!t}s -- even
    ones sharing key material, see the {!of_raw} note below -- don't trivially collide with each
    other) concatenated with an 8-byte big-endian counter that increments on every {!encrypt} call
    and never repeats within one {!t}'s lifetime. This is a deliberate rejection of a randomly
    generated nonce: GCM's 96-bit nonce space only gives a birthday-bound safety margin of roughly
    2^32 encryptions before random collisions become a real risk, which a monotonic counter avoids
    entirely -- collision is impossible as long as the counter itself never repeats, which it
    can't within a 64-bit range short of ~1.8 * 10^19 encryptions under one key.

    {b [t] is mutable.} Every {!encrypt} call advances an internal counter ref as a side effect --
    calling {!encrypt} on the same [t] twice never reuses a nonce, but this also means a [t] is
    not safe to encrypt with concurrently from two fibers/threads without external
    synchronization (the read-then-increment of the counter is not atomic), the same caveat
    {!Riptide_materialize.Materializer}'s own [write] documents for its read-join-put pattern. *)

type t
(** An unwrapped DEK: AES-256 key material plus the private nonce-prefix and counter state
    described above. Never serialize [t] itself -- use {!raw} to extract the key bytes for
    wrapping under a KEK (Task 6), which deliberately discards the nonce state (see {!of_raw}). *)

val generate : unit -> t
(** [generate ()] produces a fresh DEK: 32 bytes (256 bits) of real CSPRNG key material from
    {!Mirage_crypto_rng} plus a freshly randomized nonce prefix. Per Decision 4, call this once
    per redactable payload -- never reuse one [t] across payloads that should be independently
    redactable, since redacting one payload means discarding (or never wrapping/storing) that
    payload's own DEK, which is only a clean "throw away the key" operation if no other payload
    depends on the same key. *)

val encrypt : t -> string -> string
(** [encrypt t plaintext] encrypts [plaintext] under [t]'s key with AES-256-GCM, using [t]'s next
    nonce (advancing its internal counter as a side effect -- see the mutability note above), and
    returns the 12-byte nonce prepended to Mirage_crypto's own inline-tagged ciphertext (ciphertext
    with the GCM authentication tag appended). The nonce isn't secret, only the key is; it must
    travel with the ciphertext for {!decrypt} to recover it, hence the prepending. *)

val decrypt : t -> string -> string option
(** [decrypt t nonce_and_ciphertext] splits off the leading 12-byte nonce, then authenticates and
    decrypts the remainder under [t]'s key. Returns [None] if the input is shorter than the
    12-byte nonce, or if GCM authentication fails -- which covers both a genuinely wrong key (see
    {!of_raw}'s reconstruction path) and any tampering with the ciphertext or tag. Does not touch
    [t]'s nonce counter -- decryption reads whatever nonce is embedded in the input rather than
    generating one. *)

val raw : t -> string
(** [raw t] returns [t]'s raw 32-byte key material, discarding its nonce state -- for wrapping
    under the KEK (Task 6's own encrypt-the-DEK step). {!Mirage_crypto.AES.GCM.key} is abstract
    with no accessor recovering the original secret, so [t] retains these bytes internally
    specifically to make this possible. *)

val of_raw : string -> t
(** [of_raw raw_bytes] reconstructs a [t] from previously-extracted {!raw} key bytes -- Task 6's
    own decrypt path, after unwrapping a stored DEK under the KEK. The reconstructed [t] gets a
    brand-new random nonce prefix and a counter reset to zero; it does {b not} resume whatever
    nonce state the original [t] (the one {!raw} was called on) had reached.

    {b Concern for Task 6:} because the counter resets to zero, two live [t] values reconstructed
    from the very same raw key bytes -- e.g. via two separate {!of_raw} calls, or one {!of_raw}
    call alongside the original [t] the bytes came from -- do {b not} pick up where the other left
    off. Each gets an independently random 4-byte nonce prefix, so a nonce collision between them
    requires both an (unlikely, ~1-in-2^32) prefix collision {b and} overlapping counter values --
    which is exactly the same birthday-bound risk the deterministic-counter design above exists to
    avoid, just reintroduced at the reconstruction boundary instead of eliminated by it. Under
    Decision 4's intended usage (one fresh [t] per payload from {!generate}, encrypted exactly
    once, wrapped, and from then on only ever reconstructed via {!of_raw} for {!decrypt} -- never
    to {!encrypt} again) this is not a live hazard, since {!decrypt} never consults the nonce
    counter. It {b would} become a real hazard if Task 6 ever unwraps a stored DEK and calls
    {!encrypt} on the reconstructed [t] -- e.g. a re-wrap/rotation flow, or any design change that
    lets one DEK cover more than one payload -- since nothing in this interface prevents it or
    tracks how many payloads a given raw key has ever encrypted across process restarts. If that
    usage is ever needed, Task 6 should track nonce state externally (alongside the wrapped DEK in
    the keystore) rather than relying on a fresh {!of_raw} counter reset being safe. *)
