open Riptide_module

(* This box's own durable cosign install location (see README.md's "cosign (admission-gate
   signing) toolchain setup" section) -- everything outside /work is on this box's ephemeral
   overlay and can vanish between sessions with no restart notice, so a future session's `dune
   test` must not depend on cosign already being on PATH. Falls back to plain "cosign" (a normal
   PATH lookup) if that durable location isn't present, e.g. on a different box/CI runner that
   installs it elsewhere. *)
let cosign_path =
  if Sys.file_exists "/work/toolchain/bin/cosign" then "/work/toolchain/bin/cosign" else "cosign"

(* [Filename.temp_dir] (the function this task's own brief's pseudocode calls directly) does not
   exist in this project's actual pinned toolchain -- confirmed live, this repo's OCaml 5.0.0
   stdlib only has [Filename.temp_file] (added 3.11.2); [Filename.temp_dir] itself is a later
   (5.1+) stdlib addition. [Filename.temp_file] IS present, and already implements the secure,
   race-free unique-name generation this needs -- reused here (remove the file it creates,
   `mkdir` a directory at that same freshly-proven-unique path instead) rather than hand-rolling
   a weaker substitute. *)
let make_temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let sha256_hex path =
  let ic = open_in_bin path in
  let contents = really_input_string ic (in_channel_length ic) in
  close_in ic;
  Digestif.SHA256.(to_hex (digest_string contents))

let string_contains ~needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

(* Test-setup-only helper: shells out to the real cosign binary to generate a real keypair /
   really sign a real file, so this task's own "accepts a real signed artifact"/"rejects a
   tampered artifact" tests exercise real cosign end to end, not a mock. Not the code under test
   -- Admission.verify itself never calls this; it only ever calls `cosign verify-blob`, see
   admission.ml's own [run_cosign].

   COSIGN_PASSWORD="" is set once, process-wide, below (this test file's own top-level
   initializer) so `generate-key-pair`/`sign-blob` never block on an interactive password
   prompt under this non-interactive test runner -- confirmed live that omitting it hangs on
   "Enter password for private key:" and then fails with an ioctl error. *)
let run_cosign_setup args ~cwd =
  let cmd =
    Printf.sprintf "cd %s && %s" (Filename.quote cwd) (Filename.quote_command cosign_path args)
  in
  let exit_code = Sys.command cmd in
  if exit_code <> 0 then
    Alcotest.failf "test setup: `cosign %s` (cwd %s) failed with exit %d" (String.concat " " args)
      cwd exit_code

let () = Unix.putenv "COSIGN_PASSWORD" ""

(* Signs [artifact] in place with a freshly generated keypair, both living under [dir], entirely
   offline (no live Sigstore/Fulcio/Rekor network round trip -- see admission.ml's top comment
   for why `--tlog-upload=false --use-signing-config=false` are both required together against
   the real installed cosign v3.1.3; confirmed live that either flag alone either errors or
   still reaches the real network). Returns the path to the generated public key. *)
let sign_with_fresh_keypair ~dir artifact =
  run_cosign_setup [ "generate-key-pair" ] ~cwd:dir;
  run_cosign_setup
    [ "sign-blob"; "--key"; Filename.concat dir "cosign.key"; "--bundle";
      Filename.concat dir (Filename.basename artifact) ^ ".bundle"; "--tlog-upload=false";
      "--use-signing-config=false"; "--yes"; artifact ]
    ~cwd:dir;
  Filename.concat dir "cosign.pub"

let isolation_tier_testable =
  Alcotest.testable
    (fun fmt tier ->
      Format.pp_print_string fmt (match tier with Loader.Sfi -> "Sfi" | Loader.Microvm -> "Microvm"))
    ( = )

let test_verify_rejects_when_cosign_is_not_on_path () =
  (* Fix round 1 (review finding #1): the brief's own literal pseudocode for this test used
     ~digest:"sha256:deadbeef" ~artifact_path:"/tmp/whatever" -- a path that doesn't exist. Since
     Admission.verify's content-digest check (correctly ordered first, before cosign is ever
     invoked -- see admission.mli) short-circuits on a nonexistent/unreadable artifact, that
     version of this test never actually reached the cosign-invocation step at all: it returned
     Error for "cannot read artifact", not for anything cosign-related, so it wasn't really
     testing the missing-binary path it's named for (confirmed live by reproducing that exact
     call standalone: the real error was "admission: cannot read artifact: /tmp/whatever: No
     such file or directory"). Fixed by using a REAL artifact file whose digest genuinely
     matches ~digest, so the digest check passes and the call actually reaches the (still
     genuinely missing) cosign binary -- isolating "cosign binary missing" from "digest
     mismatch" as two distinct, separately-tested failure modes (the digest-mismatch shape is
     its own dedicated test below,
     test_verify_rejects_on_digest_mismatch_without_ever_invoking_cosign).

     ?key:None is explicit, not merely omitted: Admission.verify's own type -- ?key:string sitting
     between two required labeled arguments, with no trailing positional argument -- is exactly
     the shape the brief's own type signature specifies (Task 5's own pseudocode), but that shape
     means OCaml's optional-argument erasure does not kick in from ordinary application alone;
     confirmed live (a minimal repro of this exact arg shape) that `f ~a ~b ~c ~d` without `?key`
     leaves a residual `?key:string -> ...` function type rather than erasing to the concrete
     result type, which then fails to pattern-match against `Ok`/`Error` at all. Passing
     `?key:None` explicitly resolves it cleanly. *)
  let dir = make_temp_dir "admission_test" in
  let artifact = Filename.concat dir "module.wasm" in
  write_file artifact "fake wasm bytes";
  match
    Admission.verify ~cosign_path:"/nonexistent/cosign" ?key:None ~digest:(sha256_hex artifact)
      ~tier:Loader.Sfi ~artifact_path:artifact
  with
  | Ok _ -> Alcotest.fail "expected a closed-fail rejection"
  | Error msg ->
      (* Not just Error _ -- assert the rejection actually names the missing binary, so a future
         regression that changes WHICH check fires first (e.g. an accidental reordering) would
         be caught here instead of silently passing on a different Error for the wrong reason. *)
      Alcotest.(check bool) "error mentions the missing cosign binary" true
        (string_contains ~needle:"nonexistent/cosign" msg)

let test_verify_accepts_a_real_locally_signed_artifact () =
  (* Test setup: generate a real cosign keypair (cosign generate-key-pair, in a tmp dir),
     cosign sign-blob a real local file, then Admission.verify against that same local key --
     no live Sigstore/Fulcio/Rekor network dependency, matching the spec's own named open question
     resolved here as: local keypair signing for tests, real keyless/Fulcio flow left to
     deployment-time configuration this task does not need to exercise. *)
  let dir = make_temp_dir "admission_test" in
  let artifact = Filename.concat dir "module.wasm" in
  write_file artifact "fake wasm bytes";
  let key = sign_with_fresh_keypair ~dir artifact in
  match
    Admission.verify ~cosign_path ~key ~digest:(sha256_hex artifact) ~tier:Loader.Sfi
      ~artifact_path:artifact
  with
  | Ok v -> Alcotest.(check isolation_tier_testable) "tier recorded" Loader.Sfi v.tier
  | Error e -> Alcotest.fail e

let test_verify_rejects_a_tampered_artifact () =
  (* Same setup as the accepts-a-real-signed-artifact test above, then the artifact's bytes are
     modified after signing. The ~digest passed to Admission.verify below is deliberately the
     digest of the *tampered* (post-modification) bytes, not the originally-signed ones -- if it
     were the original digest, Admission.verify's own OCaml-side content-digest check (checked
     before cosign is ever invoked -- see admission.mli) would itself already reject the call,
     which would prove that check works but would NOT prove cosign's own real cryptographic
     signature check rejects tampered content, which is what this test exists to prove. Passing
     the tampered file's own real digest makes the OCaml-side check pass, so this call reaches
     real cosign, which must then reject it on its own: the bundle's signature covers the
     original bytes, and cosign verify-blob recomputes+checks the hash actually embedded in the
     signed payload against the artifact currently on disk. *)
  let dir = make_temp_dir "admission_test" in
  let artifact = Filename.concat dir "module.wasm" in
  write_file artifact "fake wasm bytes";
  let key = sign_with_fresh_keypair ~dir artifact in
  write_file artifact "fake wasm bytes -- TAMPERED AFTER SIGNING";
  match
    Admission.verify ~cosign_path ~key ~digest:(sha256_hex artifact) ~tier:Loader.Sfi
      ~artifact_path:artifact
  with
  | Ok _ -> Alcotest.fail "expected cosign's own signature check to reject tampered content"
  | Error _ -> ()

(* Not one of the brief's own three literal tests, but directly proves the specific design claim
   admission.mli's doc comment makes about ordering ("checked in OCaml before ever invoking
   cosign"): a fake, marker-file-writing stand-in cosign is installed at ~cosign_path, and this
   test asserts the marker is never created when the caller-supplied ~digest doesn't match the
   artifact's real content -- i.e. the rejection genuinely happens before any subprocess spawn,
   not merely also-before-cosign-succeeds. This is real, unmocked proof (a real executable that
   would genuinely run if invoked), not an assumption from reading the source. *)
let test_verify_rejects_on_digest_mismatch_without_ever_invoking_cosign () =
  let dir = make_temp_dir "admission_test" in
  let artifact = Filename.concat dir "module.wasm" in
  write_file artifact "fake wasm bytes";
  let marker = Filename.concat dir "cosign-was-invoked" in
  let fake_cosign = Filename.concat dir "cosign" in
  write_file fake_cosign (Printf.sprintf "#!/bin/sh\ntouch %s\nexit 0\n" (Filename.quote marker));
  Unix.chmod fake_cosign 0o755;
  (match
     Admission.verify ~cosign_path:fake_cosign ?key:None
       ~digest:"0000000000000000000000000000000000000000000000000000000000000000" ~tier:Loader.Sfi
       ~artifact_path:artifact
   with
  | Ok _ -> Alcotest.fail "expected the digest mismatch to be rejected"
  | Error _ -> ());
  Alcotest.(check bool) "cosign was never invoked" false (Sys.file_exists marker)

(* Second disclosed failure shape this task's brief calls out explicitly ("A nonzero exit or the
   binary missing from cosign_path both return Error _"): a real cosign invocation that runs,
   exits nonzero, and must still be rejected -- distinct from
   test_verify_rejects_when_cosign_is_not_on_path (the binary-missing shape) and distinct from
   test_verify_rejects_a_tampered_artifact (a real cosign failure via an actual cryptographic
   mismatch). Here the artifact is correctly signed and the digest matches, but ~key points at
   the WRONG (unrelated) public key, so the real, running cosign process itself exits nonzero on
   its own signature-verification logic, not because anything upstream short-circuited it. *)
let test_verify_rejects_a_real_cosign_nonzero_exit_against_the_wrong_key () =
  let dir = make_temp_dir "admission_test" in
  let artifact = Filename.concat dir "module.wasm" in
  write_file artifact "fake wasm bytes";
  let (_ : string) = sign_with_fresh_keypair ~dir artifact in
  let other_dir = make_temp_dir "admission_test_other_key" in
  run_cosign_setup [ "generate-key-pair" ] ~cwd:other_dir;
  let wrong_key = Filename.concat other_dir "cosign.pub" in
  match
    Admission.verify ~cosign_path ~key:wrong_key ~digest:(sha256_hex artifact) ~tier:Loader.Sfi
      ~artifact_path:artifact
  with
  | Ok _ -> Alcotest.fail "expected cosign to reject a signature checked against the wrong key"
  | Error _ -> ()

let tests =
  [
    ("Admission.verify rejects a closed-fail when cosign is not on PATH", `Quick,
     test_verify_rejects_when_cosign_is_not_on_path);
    ("Admission.verify accepts a real, locally-signed artifact and records its tier", `Quick,
     test_verify_accepts_a_real_locally_signed_artifact);
    ("Admission.verify rejects a tampered artifact via a real cosign signature-check failure",
     `Quick, test_verify_rejects_a_tampered_artifact);
    ("Admission.verify rejects a content-digest mismatch without ever invoking cosign", `Quick,
     test_verify_rejects_on_digest_mismatch_without_ever_invoking_cosign);
    ("Admission.verify rejects a real cosign nonzero exit against the wrong key", `Quick,
     test_verify_rejects_a_real_cosign_nonzero_exit_against_the_wrong_key);
  ]
