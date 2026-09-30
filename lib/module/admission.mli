(** Admission gate: cryptographic verification of a WASM artifact before it is ever handed to
    {!Loader} (Task 5, subtask 4).

    Every artifact must pass a real, external {{:https://github.com/sigstore/cosign}[cosign]}
    signature check before it is loaded — never a placeholder or a stubbed-out "trust it"
    shortcut. {!verify} shells out to a real, locally-installed [cosign] binary (path supplied by
    the caller via [~cosign_path], deliberately not hardcoded here — deployment picks where
    [cosign] lives, e.g. this box's own durable [/work/toolchain/bin/cosign], not this library).
    A nonzero exit from [cosign], or the binary being missing/unexecutable at [cosign_path],
    both surface as [Error _] — this gate never fails open. See [admission.ml]'s top comment for
    the exact command line(s) invoked and why.

    Consumed by Task 6: the reactor only ever loads a {!verified_artifact}, never a bare path —
    there is no code path from an on-disk artifact to {!Loader.instantiate} that
    doesn't pass through {!verify} first.

    {b Known, disclosed residual gap: this gate verifies a SIGNATURE. It does not verify
    PROVENANCE.} (Review finding I3; the design spec's own Decision 6 has been corrected to match,
    and names this as deliberately deferred follow-up work rather than something silently dropped.)
    The spec originally promised provenance verification too — [cosign verify-attestation] against
    SLSA/in-toto attestations — and commit [4193b20]'s own message claims "signature+provenance".
    Neither is true of the code: {!verify} performs a content-digest check and exactly one
    [cosign verify-blob] call, and an artifact with no attestation of any kind passes. So what a
    {!verified_artifact} actually attests is "these bytes hash to the digest the caller expected, and
    someone holding the expected key signed them" — NOT "this artifact was built by a trusted builder
    from trusted source." Doing that for real needs a policy model this function's signature does not
    yet have room for (which attestations are required; how missing vs. malformed vs.
    untrusted-issuer differ), which is why it is named as a future sub-project instead of
    half-implemented here.

    {b Known, disclosed residual gap: a {!verified_artifact}'s [tier] is bound to what was verified;
    its session-type protocol is not — nothing here even looks for one.} (Review finding I5.) The
    spec's Decision 4 originally described a module declaring its own valid call sequence "alongside
    its ABI manifest"; there is no manifest, and {!verify} inspects nothing about the artifact's
    contents beyond its digest. The protocol a module runs under is supplied by whoever calls
    {!Riptide_module.Reactor.subscribe}/{!Loader.instantiate} — see
    {!Riptide_module.Reactor.subscribe}'s own disclosure of the same gap from the consuming side —
    so a subscriber may supply any protocol at all, including one that permits calls the module's
    real behavior should never have been allowed to make. [tier] is deliberately different: it is
    carried on this record precisely so a downstream consumer never re-derives or re-trusts it. Any
    future protocol binding needs the same treatment, plus a manifest format to bind, which is
    exactly why it is deferred rather than approximated.

    **Bundle-file convention.** [cosign] itself is the source of truth for what "signed" means;
    this module does not invent its own signature format. For an artifact at path [p], the
    corresponding [cosign] verification material is expected at the sibling file [p ^ ".bundle"]
    (a [cosign sign-blob --bundle ...]-produced JSON bundle — signature, and certificate/
    transparency-log material for the keyless path). This is an adaptation, not a literal
    replay, of this task's own originating brief: the brief's own pseudocode assumed an older
    [cosign] release's [--signature <path.sig>]/[--output-signature] flags, but the actual
    installed release (v3.1.3, current [cosign] [--help] confirmed live) removed both in favor
    of [--bundle] — see [admission.ml]'s top comment for the full, empirically-verified flag
    history this module's shape is built against. *)

type verified_artifact = { local_path : string; tier : Loader.isolation_tier }
(** The result of a successful {!verify} call. [local_path] is exactly the [~artifact_path] that
    was verified; [tier] is exactly the caller-supplied [~tier], carried through unmodified —
    {!verify} never inspects or second-guesses the caller's isolation-tier choice, it only ever
    attaches it to a value that provably passed admission, so a downstream consumer (Task 6's
    reactor) never has to re-derive or separately re-trust which tier a module was admitted
    under. *)

val verify :
  cosign_path:string ->
  ?key:string ->
  digest:string ->
  tier:Loader.isolation_tier ->
  artifact_path:string ->
  (verified_artifact, string) result
(** Verify the artifact at [artifact_path], returning [Ok] only if BOTH of the following real
    checks pass:

    + **Content-digest check (checked in OCaml, first, before [cosign] is ever invoked).**
      [artifact_path]'s real SHA-256 (lowercase hex, no ["sha256:"] prefix — the same convention
      {!Riptide.Value.hash_to_hex} uses) is computed directly from the file's bytes and compared
      against the caller-supplied [~digest]. A mismatch — including the artifact simply not
      existing or not being readable — is an immediate [Error], and [cosign] is never shelled
      out to at all for this call (see [test_verify_rejects_on_digest_mismatch_without_ever_invoking_cosign]
      in [test_module_admission.ml] for a real, non-mocked proof of this: a fake, marker-writing
      substitute [cosign] is never actually invoked when the digest is wrong).
    + **Signature check (real [cosign], shelled out via [Unix.create_process], stdout+stderr
      merged into a single pipe — see [admission.ml]'s own [run_cosign] doc comment for why a
      merged single stream, not two separately-read ones, is a deliberate fix for a real
      pipe-deadlock hazard class, not an incidental simplification).** If [~key] is supplied,
      this is a real local-keypair [cosign verify-blob --key ...] call against [artifact_path]'s
      [.bundle] sibling file (see this file's top comment for the exact convention). If [~key] is
      omitted, [verify] attempts [cosign]'s keyless/Fulcio verification path instead
      ([cosign verify-blob --bundle ...] with no [--key]) — this repo's own test suite
      deliberately does not exercise that path with real assertions (no live Sigstore/Fulcio/
      Rekor network dependency in tests, matching this task's own disclosed open question), but
      the code path is real and will genuinely invoke [cosign], not a stub; wiring a real OIDC
      identity/issuer for a live keyless deployment is a deployment-time configuration concern,
      not something this function's signature needs to widen for.

    A nonzero [cosign] exit code, [cosign_path] not resolving to an executable file at all (the
    [Unix.ENOENT]-shaped failure), or any other real subprocess failure, all return [Error _] —
    never [Ok] and never a raised exception; this gate fails closed on every real failure mode it
    can produce, matching {!Loader}'s own "guard failure ⇒ total no-op"
    convention.

    **Known, disclosed, deliberately-not-engineered-around residual gap (TOCTOU).** The
    content-digest check above and [cosign]'s own read of [artifact_path] (inside the signature
    check) are two SEPARATE opens of the same path — [sha256_hex_of_file] reads it once, in
    OCaml, and then, if that passes, a freshly-spawned [cosign] process reads it again, entirely
    independently, by path. There is a real window between those two reads in which
    [artifact_path]'s on-disk contents could change (e.g. a concurrent writer, a symlink
    retarget), and nothing in this function detects or prevents that: a "verified" result only
    ever proves the digest check and the [cosign] check each separately passed against
    *whatever bytes were at that path at the moment each of them individually ran*, not that both
    checks saw the identical byte sequence. This is inherent to the "shell out to an external
    tool that re-reads the artifact by path" design this task's own brief specifies — closing it
    for real would need a materially different design (e.g. handing [cosign] an already-open file
    descriptor rather than a path, which its own CLI surface does not support; or copying the
    artifact to a fresh, exclusively-held path before either read), which is out of this task's
    scope, not merely undone here. Disclosed explicitly, per this codebase's own convention (see
    e.g. {!Loader.invoke}'s doc comment, "Known, disclosed, deliberately-not-engineered-around
    interaction"), rather than left as a silent gap behind the "never fails open" claim above —
    that claim is true of every check this function actually performs, it is not a claim that the
    two checks are atomic with each other. *)
