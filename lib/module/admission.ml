(* Admission gate (Task 5, subtask 4). See admission.mli for the full contract; this comment
   covers the two things that don't belong in the public doc comment: the real, empirically-
   verified cosign command lines this shells out to, and why they look the way they do.

   This box did not have cosign installed when this task started -- it was installed durably to
   /work/toolchain/bin/cosign (v3.1.3, the latest release at install time; see this repo's own
   README.md, "cosign (admission-gate signing) toolchain setup" section, for the exact install
   steps and why that location). Every flag below was verified by hand against that real binary
   (`cosign verify-blob --help` / `cosign sign-blob --help`, and a live generate-key-pair -> sign
   -> verify -> tamper -> verify-fails round trip) before writing any of this file, specifically
   because this task's own brief was written against an older cosign release and its literal
   pseudocode (`--signature <path>.sig` / `--output-signature`) no longer exists as of v3.1.3 --
   both flags were removed in favor of a single `--bundle <file>` JSON bundle covering signature
   plus (for the keyless path) certificate and transparency-log material.

   Two real, live-confirmed cosign v3.1.3 behaviors this module works around:

   1. By default, `cosign sign-blob`/`verify-blob` reach out to the real, public Sigstore Rekor
      transparency log over the network -- confirmed live (a `tlogEntries` block with a genuine
      `rekor.sigstore.dev` log index/checkpoint appeared in a bundle produced with no flags at
      all beyond `--bundle`). That's real, correct behavior for a genuine keyless deployment, but
      it is a live network dependency this task's own tests must not have (per the brief's own
      disclosed open question: local keypair signing for tests, no live Sigstore/Fulcio/Rekor
      network dependency in CI). Confirmed live that `--tlog-upload=false` alone is rejected
      ("not supported with --signing-config or --use-signing-config") -- it must be paired with
      `--use-signing-config=false` (verified: with both, `sign-blob` produces a bundle with no
      `tlogEntries` at all, no network round trip). The verify side's equivalent is
      `--insecure-ignore-tlog=true --insecure-ignore-sct=true` (cosign's own naming, not this
      module's -- "insecure" here means "not additionally checking Rekor inclusion/SCT", not
      "skips the actual cryptographic signature check", which this module never skips).
   2. `cosign generate-key-pair`/`sign-blob` prompt interactively for a private-key password
      unless `COSIGN_PASSWORD` is set in the environment (confirmed live: omitting it hangs on
      "Enter password for private key:" then fails with an ioctl error under a non-interactive
      test runner). This module's own `verify` path only ever reads a *public* key, which cosign
      never password-prompts for, so this only matters for this task's own test setup (signing a
      fixture), not for `verify` itself.

   Bundle-file convention: for an artifact at path [p], the verification material [cosign] reads
   is expected to already exist at the sibling file [p ^ ".bundle"] -- produced by whatever
   signed the artifact in the first place (this task's own test fixtures produce it via
   `cosign sign-blob --key ... --bundle <p>.bundle --tlog-upload=false --use-signing-config=false
   --yes <p>`; a real deployment's own signing pipeline is responsible for the equivalent, this
   module only ever reads it). *)

type verified_artifact = { local_path : string; tier : Loader.isolation_tier }

let bundle_path_for artifact_path = artifact_path ^ ".bundle"

(* Real SHA-256 of a file's bytes, lowercase hex -- the content-digest half of the admission
   check, checked entirely in OCaml with no external tool. Mirrors the encoding convention
   Riptide.Value.hash_to_hex already uses elsewhere in this codebase (lowercase hex, no
   "sha256:" scheme prefix), so a caller computing ~digest with that same convention (as this
   task's own tests do) needs no extra translation.

   Deliberately only catches [Sys_error] (the real shape of "no such file", "permission denied",
   etc. from the stdlib channel functions below) -- not a blanket exception handler, so a genuine
   programming error here (e.g. Out_of_memory on a pathological input) is never silently
   swallowed into an ordinary-looking [Error], matching this codebase's own established
   exception-handling discipline (see loader.mli's [cleanup] doc comment for the same
   distinction: real failures modes are caught and converted, [Out_of_memory]/[Stack_overflow]
   are deliberately let through). *)
let sha256_hex_of_file path =
  try
    let ic = open_in_bin path in
    let contents =
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () -> really_input_string ic (in_channel_length ic))
    in
    Ok Digestif.SHA256.(to_hex (digest_string contents))
  with Sys_error msg -> Error (Printf.sprintf "admission: cannot read artifact: %s" msg)

(* Runs [cosign_path] with [args] via [Unix.create_process] (never a shell -- no [sh -c]
   involved, so there is no shell-quoting hazard for any argument, including a caller-supplied
   path), with the child's stdout AND stderr both pointed at the SAME pipe write-end (a single
   merged stream), and its stdin pointed at [/dev/null].

   Fix round 1 (review finding #2): this used to read cosign's stdout and stderr from two
   SEPARATE pipes, sequentially (stdout fully, then stderr fully). That is a real deadlock hazard
   -- if combined output ever exceeded the OS pipe buffer (~64KB, historically) before the
   undrained pipe was read, the child would block writing to the full pipe forever, and this
   function would be blocked reading the OTHER (empty) pipe forever, with no timeout anywhere.
   Real `cosign` output is small today so this never triggered in practice, but it's the same
   subprocess-hygiene hazard class Task 3 (immediately before this one) found real, multi-round
   bugs in for [loader.ml]'s own forked-child containment. Fixed by removing the hazard entirely
   rather than working around it with a concurrent-read/[Unix.select] mechanism: merging stdout
   and stderr into one pipe means there is only ever one fd to read, so there is no "other pipe"
   to leave undrained. This function only ever uses the merged output for (a) the exit-0 success
   value, which no caller inspects (see [verify] below -- [_stdout] is intentionally unused), and
   (b) an error-message string on non-exit-0, where interleaved stdout+stderr content is exactly
   as useful for a human/log reader as two separately-labeled streams would have been -- nothing
   in this module parses cosign's output as structured data.

   [/dev/null] as the child's stdin (rather than, say, an immediately-closed pipe) guarantees a
   spawned `cosign` can never block on a stdin read even if a future call shape ever needed one;
   today's [cosign verify-blob] invocations (both the [~key] and keyless forms) never read stdin
   at all.

   Returns the real merged output on a genuine exit-0; [Error _] on every other real outcome: the
   binary missing/unexecutable at [cosign_path] (a real [Unix.Unix_error], confirmed live:
   `Unix.create_process "/nonexistent/cosign" ...` raises `Unix_error(ENOENT, "create_process",
   ...)` synchronously in the caller, before any process exists to leak -- nothing was ever
   forked on this path, so there is nothing to reap or close beyond the pipe/devnull fds this
   function itself opened), a nonzero exit, or the child dying to a signal. Every fd this
   function opens (the pipe's two ends, [/dev/null]) is closed on every exit path, and every
   successfully spawned child is reaped via [Unix.waitpid] -- confirmed live via a `ps -eo
   pid,ppid,stat,cmd | awk '$3 ~ /Z/'` sweep showing no zombies after a full test run exercising
   both the missing-binary and the nonzero-exit paths. The pipe is created with [~cloexec:true]
   (and [/dev/null] opened with [O_CLOEXEC]) specifically so the ORIGINAL, higher-numbered fds
   this function holds never leak into the child at all: [Unix.create_process]'s internal
   [dup2] onto fds 0/1/2 always produces non-cloexec copies regardless of the source fd's own
   flag (standard POSIX [dup2] semantics), so marking the sources cloexec here only closes the
   *extra*, otherwise-unnecessary duplicate references a naive implementation would otherwise
   leave open in the child. *)
let run_cosign cosign_path args =
  match
    try
      let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
      let output_read, output_write = Unix.pipe ~cloexec:true () in
      Ok (devnull, output_read, output_write)
    with Unix.Unix_error (err, fn, arg) ->
      Error
        (Printf.sprintf "admission: cannot prepare cosign subprocess (%s: %s %s)" fn
           (Unix.error_message err) arg)
  with
  | Error _ as e -> e
  | Ok (devnull, output_read, output_write) -> (
      let spawn_result =
        try
          Ok
            (Unix.create_process cosign_path
               (Array.of_list (cosign_path :: args))
               devnull output_write output_write)
        with Unix.Unix_error (err, fn, arg) ->
          Error
            (Printf.sprintf "admission: cannot run cosign at %S (%s: %s %s)" cosign_path fn
               (Unix.error_message err) arg)
      in
      match spawn_result with
      | Error _ as e ->
          Unix.close devnull;
          Unix.close output_read;
          Unix.close output_write;
          e
      | Ok pid ->
          Unix.close devnull;
          Unix.close output_write;
          let output_ic = Unix.in_channel_of_descr output_read in
          let output_content = In_channel.input_all output_ic in
          close_in output_ic (* also closes the underlying output_read fd *);
          let _, status = Unix.waitpid [] pid in
          (match status with
          | Unix.WEXITED 0 -> Ok output_content
          | Unix.WEXITED code ->
              Error
                (Printf.sprintf "admission: cosign exited %d: %s" code
                   (String.trim output_content))
          | Unix.WSIGNALED signal ->
              Error (Printf.sprintf "admission: cosign killed by signal %d" signal)
          | Unix.WSTOPPED signal ->
              Error (Printf.sprintf "admission: cosign stopped by signal %d" signal)))

let cosign_verify_args ~key ~artifact_path =
  let bundle = bundle_path_for artifact_path in
  match key with
  | Some key_path ->
      [ "verify-blob"; "--key"; key_path; "--bundle"; bundle; "--insecure-ignore-tlog=true";
        "--insecure-ignore-sct=true"; artifact_path ]
  | None ->
      (* Keyless/Fulcio path: real, not stubbed, but genuinely unconfigured here -- a live
         deployment needs its own --certificate-identity/--certificate-oidc-issuer (or the
         equivalent regexp forms), which is deployment-time configuration this function's own
         signature deliberately doesn't grow to carry (see admission.mli's doc comment on
         [verify] for the full reasoning). This will genuinely invoke cosign and genuinely fail
         closed absent that configuration -- it is not a silent no-op. *)
      [ "verify-blob"; "--bundle"; bundle; artifact_path ]

(* [@warning "-16"]: this signature's shape (an optional [?key] followed only by further
   *labeled* -- not positional -- required arguments, no trailing [()]) is exactly what Task 5's
   own brief specifies and this task's own tests call it with; OCaml's warning 16
   ("unerasable-optional-argument") fires on this shape regardless of the accompanying .mli
   constraining it, purely from how the value binding itself is parsed. Confirmed live in
   isolation (a minimal repro of this exact arg shape) that neither an .mli ascription nor an
   inline type annotation on the [let] suppresses it -- only this per-binding attribute does,
   without changing the function's actual arity/labels to work around a lint. *)
let[@warning "-16"] verify ~cosign_path ?key ~digest ~tier ~artifact_path =
  match sha256_hex_of_file artifact_path with
  | Error _ as e -> e
  | Ok actual_digest ->
      if not (String.equal actual_digest digest) then
        Error
          (Printf.sprintf
             "admission: content-digest mismatch for %S (expected %s, got %s) -- rejected \
              before invoking cosign"
             artifact_path digest actual_digest)
      else (
        match run_cosign cosign_path (cosign_verify_args ~key ~artifact_path) with
        | Error _ as e -> e
        | Ok _stdout -> Ok { local_path = artifact_path; tier })
