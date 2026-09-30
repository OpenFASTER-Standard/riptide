(* test/tcp_emfile_probe.ml

   Standalone helper process for [test_transport_tcp.ml]'s
   [test_emfile_on_accept_does_not_kill_the_listener]. See that test's own top comment for why
   this has to be a real, separate OS process (exec'd under a real, shell-level [ulimit -n]) rather
   than anything done inside the main [test_riptide] binary itself -- the exact same reasoning, and
   the exact same fork+exec-under-a-lowering-[ulimit] technique, as
   [file_storage_o_direct_probe.ml] uses for a real [EFBIG] (Task 19), just [-n] (RLIMIT_NOFILE)
   instead of [-f] (RLIMIT_FSIZE).

   This process does exactly one thing: bring up one real, single-node [Riptide_transport.Tcp.t]
   (a "cluster" of exactly itself, so [Tcp.create] returns immediately -- there is no other peer to
   dial or wait for) listening on the port given as [Sys.argv.(1)], with a deliberately huge
   [~max_connections] so Task 28's own admission semaphore can never be the thing that blocks an
   [accept(2)] call -- the whole point of this probe is to drive a REAL [EMFILE] out of [accept(2)]
   itself, which happens before a semaphore permit is even consulted (see [run_accept_loop]'s own
   comment on that ordering), not to re-test the semaphore cap [test_accept_loop_caps_concurrent_connections]
   already covers.

   It then blocks forever ([Eio.Fiber.await_cancel]), so the only two ways this process ever ends
   are: (a) the parent test kills it once the test is done, or (b) [run_accept_loop]'s own fatal
   path re-raises past [accept_max_consecutive_errors], which fails the switch passed to
   [Tcp.create] and propagates all the way out of [Eio_main.run] as an uncaught exception -- a
   real, externally-observable process death. That distinction (still running vs. exited) is
   exactly the parent test's oracle for "did the listener survive?". *)

let () = Mirage_crypto_rng_unix.use_default ()

let () =
  let port = int_of_string Sys.argv.(1) in
  let my_id = 1 in
  let ca = Riptide_pki.Ca.generate_root ~common_name:"riptide-tcp-emfile-probe-root" in
  let cert, priv_key = Riptide_pki.Ca.sign_leaf ca ~common_name:"peer-1.riptide.test" ~valid_days:1 in
  let tls =
    Riptide_transport.Tls_identity.create ~trust_anchor:ca.Riptide_pki.Ca.cert ~cert ~priv_key
  in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run (fun sw ->
      let (_ : Riptide_transport.Tcp.t) =
        Riptide_transport.Tcp.create ~sw ~net ~clock ~my_id ~peers:[ (my_id, "127.0.0.1", port) ]
          ~tls ~max_connections:1_000_000 ()
      in
      (* Printed (and immediately flushed) only once the listening socket is actually bound --
         [Tcp.create] calls [Eio.Net.listen] before forking the accept loop -- so the parent's own
         poll-connect readiness loop has a real, if redundant, marker in the log even though it
         does not gate on this line directly (see that test's own comment on why polling a real
         connect is used instead). *)
      print_string "READY\n";
      flush stdout;
      Eio.Fiber.await_cancel ())
