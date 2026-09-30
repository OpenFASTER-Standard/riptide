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
    + **Signature check (real [cosign], shelled out via [Unix.open_process_args_full]).** If
      [~key] is supplied, this is a real local-keypair [cosign verify-blob --key ...] call
      against [artifact_path]'s [.bundle] sibling file (see this file's top comment for the
      exact convention). If [~key] is omitted, [verify] attempts [cosign]'s keyless/Fulcio
      verification path instead ([cosign verify-blob --bundle ...] with no [--key]) — this repo's
      own test suite deliberately does not exercise that path with real assertions (no live
      Sigstore/Fulcio/Rekor network dependency in tests, matching this task's own disclosed
      open question), but the code path is real and will genuinely invoke [cosign], not a stub;
      wiring a real OIDC identity/issuer for a live keyless deployment is a deployment-time
      configuration concern, not something this function's signature needs to widen for.

    A nonzero [cosign] exit code, [cosign_path] not resolving to an executable file at all (the
    [Unix.ENOENT]-shaped failure), or any other real subprocess failure, all return [Error _] —
    never [Ok] and never a raised exception; this gate fails closed on every real failure mode it
    can produce, matching {!Loader}'s own "guard failure ⇒ total no-op"
    convention. *)
