(* WASM loader: instantiation, host ABI, SFI isolation (Task 5, subtask 3 / Decision 5).

   ── What the installed `wasmtime` OCaml binding (v0.0.3) actually gives us ──

   Read directly from its installed .mli/.ml (opam root's lib/wasmtime/{wrappers,val,
   extern_ref}.mli, and the package's own source checkout under
   .opam-switch/sources/wasmtime.0.0.3/), not assumed from the plan's high-level description.

   0. THE INSTALLED LIBRARY (v0.22.0-linked, as opam originally pinned it) CANNOT ACTUALLY RUN A
      COMPILED WASM FUNCTION AT ALL ON THIS BOX'S CPU. Before any of the fuel/memory-limit design
      questions below even mattered, calling `wasm_func_call` (via any path -- this binding's,
      or a minimal standalone C program linked directly against the same .so) reliably aborted
      the whole process: `thread '<unnamed>' panicked at 'assertion failed: res.eax == 0',
      raw-cpuid-8.1.2/src/lib.rs:295`. Root-caused live, not just observed: this box's CPU
      (Xeon Platinum 8581C, an Emerald/Granite-Rapids-class part exposing AMX/AVX-512-FP16/etc
      CPUID leaves that plainly did not exist when raw-cpuid 8.1.2 was written circa 2020)
      returns CPUID leaf/subleaf data that crate version's feature-detection logic does not
      handle -- confirmed independent of this OCaml binding (a bare C program crashes
      identically) and independent of threading (crashes on the plain main thread, not just
      from a spawned pthread/Domain). No config flag in the installed library averts this (no
      way to disable Cranelift's host-feature autodetection is exposed). This is a genuine,
      hard environment/library-version defect, not a design question -- and "no spec without
      running code" (this repo's own CLAUDE.md) makes working around it mandatory, not optional:
      a loader that cannot call any WASM function isn't a loader.

      Resolution: this task locally patched the *installed* `wasmtime` OCaml package (still
      version 0.0.3 by name/API, since Task 3 never touches this repo's own `dune-project`/opam
      constraints) to link against wasmtime's official v49.0.1 C-API release instead of
      0.22.0 -- verified this specific CPU's CPUID data no longer trips a Rust panic on real
      execution. The two source files patched are `bindings.ml`/`wrappers.ml`/`wrappers.mli`
      under this switch's `.opam-switch/sources/wasmtime.0.0.3/`; see each file's own top
      comment there for the exact API-shape adjustments this required (a few `wasmtime_`-
      prefixed convenience functions the old binding used were removed/renamed upstream between
      0.22.0 and v49 -- WASI/Linker/extern_ref support, none of it used by Riptide's own ABI,
      was dropped rather than ported; the still-present, portable, non-"wasmtime_"-prefixed
      `wasm_c_api` -- module/instance/func creation and calls -- is what this loader now runs
      on). Two more *genuine, pre-existing* bugs in the upstream OCaml binding's GC-liveness
      handling surfaced once real execution was possible for the first time (both fixed in the
      same patched `wrappers.ml`, both independent of the v49 swap itself): (a) `new_instance`
      never kept host-function imports reachable for the *instance's* lifetime, only through
      the instantiate call itself, so a later major GC could collect a still-needed host
      callback out from under a live instance; (b) `Func_type.val_type`/`Func.of_func`'s
      `coerce (Foreign.funptr ..) (static_funptr ..) f` pattern only `keep_alive`d the *coerced*
      result, not the original closure `f` that ctypes-foreign's own internal registry actually
      keys off, so a major GC could mark a still-in-use host callback's registry entry expired
      (`Ctypes_ffi_stubs.CallToExpiredClosure`) out from under a live Func. Both reproduced with
      minimal standalone scripts and fixed by making the actually-load-bearing value a real,
      named GC root kept alive on the right object's finalizer. See task-3-report.md for the
      full trail (every standalone repro, in order, with exact error text).

   1. NO FUEL API IN THE THIN OCAML WRAPPER. `wasmtime.h`'s real fuel-metering functions
      (`wasmtime_context_set_fuel`/`add_fuel`) exist in v49 (confirmed via nm) but live on the
      *modern*, `wasmtime_context_t`-based API generation -- a different, larger surface (value-
      type funcs/instances, vec-based calls) from the classic `wasm_c_api` this patched binding
      now runs on. Adopting it wholesale was out of scope for a single task (see point 0's own
      "not touching WASI/Linker" boundary) -- classic `wasm_c_api` genuinely has no fuel concept
      at any version.

      Resolution: wall-clock containment via a real, separate OS PROCESS (`Unix.fork`), not an
      OCaml-level race. First attempt was an OCaml 5 `Domain.spawn` race (poll an `Atomic.t`
      against a deadline, abandon the domain on timeout) -- this compiled and passed in
      isolation, but genuinely deadlocks the whole process under real load: a truly-infinite
      guest loop with no host calls and no allocation never reaches an OCaml safepoint, so once
      abandoned it can *never* be safepointed for a later stop-the-world major GC phase (which
      OCaml 5's multicore GC requires cooperation from every live domain for) -- reproduced live
      as `dune test`/a standalone repro simply hanging forever (not crashing) the moment the
      runaway fixture's fuel timeout was hit, confirmed via `timeout` never returning control.
      Forking instead means the runaway execution lives in its own address space and process:
      the parent can `SIGKILL` it outright on timeout (real containment, not just abandonment)
      with zero risk to the parent's own GC. Host-function calls made *during* the forked call
      (this task's own `log`, potentially `read_materialized`/`propose_write`) are relayed back
      to the parent over a pipe protocol (see `Sink`/`run_contained` below) so their real,
      caller-supplied side effects (e.g. the `logged` ref the brief's own tests assert against)
      are still observed by the caller, not stranded in the forked child's own copy-on-write
      memory. This is the real "closest available equivalent" to wasmtime's own fuel metering
      this task lands on -- not a first-choice design, an evidence-driven one after the simpler
      option demonstrably deadlocked.

   2. Loading WAT text directly turns out to have no mismatch at all: `Wasmtime.wat_to_wasm` is
      real and bound (`wasmtime_wat2wasm`), and per wasmtime's own C API semantics, it accepts
      *either* WAT text or an already-binary WASM module (binary input passes through unchanged).
      So `module_bytes` is run through `wat_to_wasm` unconditionally here, accepting both
      transparently -- no special-casing needed.

   3. NO WAY TO QUERY EXPORT NAMES, AND NO BY-NAME IMPORT RESOLUTION. `wasm_instance_exports`
      returns an unnamed, positional `Extern.t list`; this binding has no `wasm_exporttype_name`
      (or any module-introspection function) bound at all, and `new_instance`'s `~imports` is
      filled purely positionally, matching the guest's own import-section order. Resolution:
      `Wasm_binary` below parses the compiled module's own import/export sections directly (a
      small, well-defined slice of the WASM binary format, spec section 5.5) -- independent of
      anything the OCaml binding provides. This recovers real by-name export lookup for
      `invoke`'s `entrypoint`, and lets `instantiate` supply only the host imports a guest
      module actually declares (by name), rather than forcing every guest to import an
      artificial, fixed set of unused host functions just to keep positional arities aligned.

   ── The guest ABI itself (this task's own hand-rolled convention, Decision 3) ──

   - A guest imports whichever of `host.log` / `host.read_materialized` / `host.propose_write` it
     needs, each `(param i32 i32) -> ...` (a pointer+length pair into the guest's own linear
     memory for the "bytes in" side).
   - A guest must export its linear memory as "memory".
   - `invoke`'s entrypoint is `(param arg_ptr: i32, arg_len: i32) -> (result_ptr: i32, result_len:
     i32)`. Before calling, the host writes the caller's `arg` bytes into guest memory at a fixed
     scratch offset (`arg_scratch_offset`); after the call returns, the host reads `result_len`
     bytes back out of guest memory starting at `result_ptr`. The guest owns/allocates its own
     buffers (no allocator export exists or is assumed -- these are hand-written fixtures, not
     output of a real guest toolchain).
   - `read_materialized`/`propose_write` follow the same ptr+len convention for their own
     bytes-in/bytes-out; see `make_host_extern` below for the exact per-function shapes. Task 3's
     own fixtures don't exercise either (only `log`), so this is this task's own forward-looking,
     provisional design for Task 6's real module to pressure-test, per this repo's CLAUDE.md
     "Expect the first extension mechanism to need real revision". *)

module W = Wasmtime.Wrappers
module Val = Wasmtime.Val

type isolation_tier = Sfi | Microvm

type host_functions = {
  read_materialized : merge_key:string -> bytes option;
  propose_write : bytes -> (unit, string) result;
  log : string -> unit;
}

(* Which side of the fork a given piece of this loader is running on, and therefore how a
   host-function call reaches the real, caller-supplied [host_functions].

   [Direct host] holds those real closures and is what a [t] is created with. [Relay] is switched
   to only inside a just-forked *child* (see [run_contained]) -- copy-on-write means mutating this
   ref in the child never touches the parent's own copy, so the parent keeps holding [Direct]
   throughout, untouched by whatever the child does with its own private copy of this same cell.

   The two arms are consumed by two different, non-overlapping pieces of code, and that split is an
   invariant worth stating (review finding M2, which found the two mixed up):
   - the PARENT only ever reads [Direct], via [supervise_child]'s own [host_of_sink], when servicing
     a relayed call on the guest's behalf;
   - a host-import CLOSURE ([make_host_extern] below) only ever reads [Relay], because guest code is
     only ever executed by the forked child ({!invoke} -> [run_contained] is the sole caller of
     [W.Wasmtime.func_call_list], and it always forks first).
   Both directions are asserted rather than assumed -- [host_of_sink] and [relay_of_sink] each fail
   loudly on the arm they must never see. A future non-forked/in-process execution tier (the obvious
   candidate: an amortized, pooled dispatch path -- see Reactor's own disclosed "no per-dispatch
   amortization" gap) is exactly what would make a host-import closure legitimately need [Direct],
   and [relay_of_sink] is then the one place that has to grow a real second arm; that is a
   deliberate future extension point, not a path anything takes today. *)
type sink = Direct of host_functions | Relay of { req_w : Unix.file_descr; resp_r : Unix.file_descr }

type t = {
  instance : W.Instance.t;
  exports : W.Extern.t list;
  export_positions : (string, int) Hashtbl.t;
  memory : W.Memory.t option;
  sink : sink ref;
  (* Task 4: this [t]'s own, private session-type checker (Riptide_module.Protocol) -- created
     once, at [instantiate] time, via [Protocol.start]. Never shared across [t] values: since
     [instantiate] already creates a fresh [t] per call (Decision 5, this file's top comment),
     each [t] -- and therefore each [protocol_checker] -- belongs to exactly one caller by
     construction, which is what makes two concurrent [instantiate] calls' checkers independent
     with no extra locking needed (see [test_two_concurrent_invocations_of_the_same_module_do_not_
     share_protocol_state] in test_module_loader.ml). A [ref], not a plain field, because
     [Protocol.step] is functional (returns a new [checker] rather than mutating one in place) and
     [invoke] needs to persist the advanced state across separate calls on the same [t] --
     the same "mutate via a ref cell on an otherwise-immutable record" pattern [sink] above
     already uses for the same reason. *)
  protocol_checker : Protocol.checker ref;
}

(* ── Minimal WebAssembly binary-format section parsing ──────────────────────────────────────
   Just enough of the WASM binary format (spec section 5.5: modules are `magic(4) version(4)
   section*`, each section `id(1) size(uleb32) content(size bytes)`) to read the import and
   export sections -- see this file's top comment for why. *)
module Wasm_binary = struct
  let read_u8 s pos = Char.code s.[pos], pos + 1

  let read_uleb32 s pos =
    let rec loop shift acc pos =
      let byte = Char.code s.[pos] in
      let acc = acc lor ((byte land 0x7f) lsl shift) in
      if byte land 0x80 = 0 then acc, pos + 1 else loop (shift + 7) acc (pos + 1)
    in
    loop 0 0 pos

  let read_name s pos =
    let len, pos = read_uleb32 s pos in
    String.sub s pos len, pos + len

  let iter_sections s ~f =
    let len = String.length s in
    let rec loop pos =
      if pos >= len then ()
      else
        let id, pos = read_u8 s pos in
        let size, pos = read_uleb32 s pos in
        f id s pos;
        loop (pos + size)
    in
    loop 8 (* skip the 4-byte magic + 4-byte version header *)

  (* The guest module's own declared linear-memory limits (section id 5 -- MVP wasm permits at
     most one locally-declared memory, matching this loader's own "guest must export exactly one
     memory named \"memory\"" ABI convention, so the first entry is the only one that matters).
     [None] means the module declares no local memory at all (nothing for [instantiate]'s own cap
     check below to act on -- a missing "memory" export is instead [invoke]'s problem, via
     [find_memory]). [Some None] means a memory IS declared but with no maximum at all (flag byte
     0x00): unbounded growth, which this loader treats as itself a violation, not a pass -- see
     [instantiate]. [Some (Some max)] is the module's own declared maximum, in pages. *)
  let declared_memory_max_pages wasm : int option option =
    let result = ref None in
    iter_sections wasm ~f:(fun id s pos ->
        if id = 5 (* memory section *) then (
          let count, pos = read_uleb32 s pos in
          if count > 0 then (
            let flag, pos = read_u8 s pos in
            let _min, pos = read_uleb32 s pos in
            if flag land 1 = 1 then result := Some (Some (fst (read_uleb32 s pos)))
            else result := Some None)));
    !result

  (* name -> position in the flat vector `wasm_instance_exports` returns. The WASM spec
     guarantees that vector is exactly the export section's own entries, in order -- one entry
     per export regardless of kind -- so this is a correct, complete map. *)
  let export_positions wasm : (string, int) Hashtbl.t =
    let table = Hashtbl.create 8 in
    iter_sections wasm ~f:(fun id s pos ->
        if id = 7 (* export section *) then (
          let count, pos = read_uleb32 s pos in
          let rec loop i pos =
            if i >= count then ()
            else
              let name, pos = read_name s pos in
              let _kind, pos = read_u8 s pos in
              let _index, pos = read_uleb32 s pos in
              Hashtbl.replace table name i;
              loop (i + 1) pos
          in
          loop 0 pos));
    table

  (* (module_name, field_name) for every *function* import, in the module's own import-section
     order -- the same order `new_instance`'s positional `~imports` must supply externs in.

     Raises a clear [Failure] on a table/memory/global import -- not supported by this task's
     host ABI, which only ever supplies function imports (see [instantiate]/[build_imports]).
     This used to only be true in this doc comment, not the code below it: a table/memory/global
     import was silently *skipped* (correctly parsed past, structurally, so later entries still
     decoded right) but never actually rejected, so a module importing one of those instead of a
     function fell through all the way to [new_instance] with a too-short positional imports
     list, and only failed there, opaquely, via wasmtime's own arity-mismatch [Trap] -- not the
     clear, documented [Failure] every other {!instantiate}-time rejection in this file raises.
     Found by code review as a narrow, real mismatch against [loader.mli]'s "instantiate-time
     failures are [Failure]" contract while re-verifying the memory-limit fix (a module
     *importing* memory rather than declaring it locally is exactly one way to hit this, since
     [declared_memory_max_pages] above only inspects locally-declared memories). Fixed here by
     actually raising, matching what this comment already (wrongly) claimed. *)
  let func_imports wasm : (string * string) list =
    let acc = ref [] in
    let kind_name = function
      | 1 -> "table"
      | 2 -> "memory"
      | 3 -> "global"
      | k -> Printf.sprintf "kind %d" k
    in
    iter_sections wasm ~f:(fun id s pos ->
        if id = 2 (* import section *) then (
          let count, pos = read_uleb32 s pos in
          let rec loop i pos =
            if i >= count then ()
            else
              let module_name, pos = read_name s pos in
              let field_name, pos = read_name s pos in
              let kind, pos = read_u8 s pos in
              match kind with
              | 0 (* func *) ->
                let pos = snd (read_uleb32 s pos (* typeidx *)) in
                acc := (module_name, field_name) :: !acc;
                loop (i + 1) pos
              | 1 | 2 | 3 ->
                failwith
                  (Printf.sprintf
                     "Loader.instantiate: guest module imports a %s (%S.%S) -- only function \
                      imports from \"host\" are supported"
                     (kind_name kind) module_name field_name)
              | k ->
                failwith (Printf.sprintf "Loader.instantiate: guest module imports unsupported kind %d" k)
          in
          loop 0 pos));
    List.rev !acc
end

(* Stands in for wasmtime's own per-instruction fuel metering (unavailable on the classic
   wasm_c_api this loader runs on -- see top comment point 1). Generous relative to any test
   fixture's real work (a single host call), far below "looks hung" to a human running
   `dune test`. *)
let fuel_budget_seconds = 2.0

(* Blocked (via [Unix.sigprocmask]) for the duration of [supervise_child]'s own [cleanup]
   sequence (kill/waitpid/close/close) -- see [cleanup]'s own comment for why. Every genuinely
   *asynchronous*, externally-deliverable POSIX signal OCaml exposes a named constant for.
   Deliberately excludes: [Sys.sigkill]/[Sys.sigstop] (POSIX-unblockable -- [sigprocmask] just
   silently ignores them if included, so omitting them changes nothing, but they're omitted for
   clarity); and the *synchronous* fault signals ([Sys.sigsegv]/[sigbus]/[sigill]/[sigfpe]/
   [sigtrap]/[sigsys]) -- blocking one of those and then actually triggering it is undefined
   behavior at the OS level, and none of them can plausibly originate from [cleanup]'s own few,
   simple syscalls anyway (a real libwasmtime-side fault happens in the forked CHILD, an
   entirely separate process/address space unaffected by the PARENT's own signal mask here). *)
let signals_to_mask_during_cleanup =
  [
    Sys.sigalrm;
    Sys.sigvtalrm;
    Sys.sigprof;
    Sys.sigint;
    Sys.sigterm;
    Sys.sighup;
    Sys.sigquit;
    Sys.sigusr1;
    Sys.sigusr2;
    Sys.sigpipe;
    Sys.sigchld;
    Sys.sigtstp;
    Sys.sigttin;
    Sys.sigttou;
    Sys.sigpoll;
    Sys.sigurg;
    Sys.sigxcpu;
    Sys.sigxfsz;
    (* Neither unblockable nor a synchronous fault, so both genuinely belong in the list above
       under its own stated rule -- omitted from the first version of it purely by oversight,
       which made that "every asynchronous signal OCaml names a constant for" claim false as
       written (caught by code review, round 4). Harmless as an omission today (nothing anywhere
       in this repo installs an OCaml handler for either, so neither can currently produce an
       OCaml-level exception mid-[cleanup] at all), but a list whose documented invariant is
       "exhaustive" has to actually be exhaustive -- otherwise the next reader reasonably infers
       an exclusion was deliberate and looks for the reason. [Sys.sigcont] in particular IS
       blockable (unlike its [Sys.sigstop] counterpart), and [Sys.sigabrt] is only "synchronous"
       when self-raised via [abort]; both are freely deliverable from another process via
       [kill]. *)
    Sys.sigabrt;
    Sys.sigcont;
  ]

(* Non-zero ONLY for the duration of [For_testing.simulate_signal_in_cleanups_pre_mask_window],
   and consumed (reset to zero) by the very first [cleanup] attempt that reads it, so exactly one
   attempt is widened -- see that function, and [cleanup]'s own doc comment (round 4), for what
   that reproduces and why a ONE-SHOT widening is the right shape for it (widening every attempt
   against a repeating signal would simply never converge, which proves nothing about the retry
   loop and everything about the injection). Zero on every production path, where the entire cost
   is one float comparison per [cleanup] attempt. *)
let pre_mask_window_widening_for_testing = ref 0.

(* The real linear-memory page limit the brief's own Step 3 text calls for ("a linear-memory
   page limit set at instantiation"). One WASM page is 64 KiB; 1024 pages is 64 MiB -- generous
   enough for any module this task's own fixtures or Task 6's first real module plausibly needs
   to hold, while remaining a small, bounded fraction of host memory a single hostile or buggy
   guest could ever claim (unlike the guest's own self-declared limit alone, which is under full
   guest control and enforces nothing against an adversarial module -- see [check_memory_limit]
   below and the code-review finding this closes). Revisit once Task 6's real module has an
   actual, measured working-set size to size this against instead of a round, defensible guess. *)
let memory_pages_cap = 1024

let read_guest_bytes memory ~ptr ~len = Bytes.of_string (W.Memory.to_string memory ~pos:ptr ~len)

let write_guest_bytes memory ~ptr bytes =
  Bytes.iteri (fun i c -> W.Memory.set memory ~pos:(ptr + i) c) bytes

(* Fixed scratch offset `invoke` writes its caller's `arg` bytes to before calling the guest's
   entrypoint -- see top comment. Comfortably clear of a guest's own small hand-written data
   segments (this task's fixtures only ever use a handful of bytes starting at offset 0). *)
let arg_scratch_offset = 0x2000

(* ── Tiny framed-message protocol over the pipes [run_contained] sets up ────────────────────
   A forked child's host-import closures (via [Relay]) use this to relay a host-function call
   back to the parent (which owns the real [host_functions]) and get its result back, since a
   fork's copy-on-write memory means calling the real closures *in the child* would only ever
   mutate the child's own private copy of whatever they close over (e.g. the `logged` ref
   `test_module_loader.ml`'s own tests assert against) -- invisible to the parent/caller. Every
   message is a single byte tag, a 4-byte big-endian length, then that many payload bytes;
   responses (parent -> child) reuse the same framing, tag byte unused/zero. *)
module Pipe_protocol = struct
  let write_exact fd bytes =
    let len = Bytes.length bytes in
    let rec loop pos = if pos < len then loop (pos + Unix.write fd bytes pos (len - pos)) in
    loop 0

  let read_exact fd len =
    let buf = Bytes.create len in
    let rec loop pos =
      if pos < len then (
        let n = Unix.read fd buf pos (len - pos) in
        if n = 0 then failwith "Loader: unexpected EOF on internal containment pipe";
        loop (pos + n))
    in
    loop 0;
    buf

  let write_u32 fd n =
    let b = Bytes.create 4 in
    Bytes.set_int32_be b 0 (Int32.of_int n);
    write_exact fd b

  let read_u32 fd = Bytes.get_int32_be (read_exact fd 4) 0 |> Int32.to_int
  let write_frame fd (payload : bytes) = write_u32 fd (Bytes.length payload); write_exact fd payload
  let read_frame fd = read_u32 fd |> read_exact fd
  let write_msg fd ~tag (payload : bytes) = write_exact fd (Bytes.make 1 tag); write_frame fd payload

  let read_msg fd =
    let tag = Bytes.get (read_exact fd 1) 0 in
    tag, read_frame fd
end

(* The import-closure-side mirror of [supervise_child]'s own [host_of_sink]: a host-import closure
   runs only ever in the forked child, so its sink is always [Relay] (see the [sink] type's own
   comment for the full invariant and the one future change that would alter it). Asserting that,
   rather than keeping an unreachable [Direct] arm that quietly calls the parent's real closures from
   whichever process happens to be running, is review finding M2's resolution: the old dead arm made
   it impossible for a reader to tell whether in-process execution was a supported mode. Reached at
   all, this raises inside guest execution, where the child's own guard turns it into an ordinary
   containment failure -- loud in the result, never a silent wrong-process side effect. *)
let relay_of_sink (sink : sink ref) =
  match !sink with
  | Relay { req_w; resp_r } -> (req_w, resp_r)
  | Direct _ ->
    failwith
      "Loader: a host-import closure ran with a Direct sink -- guest code is only ever executed by \
       run_contained's forked child, which always switches to Relay first"

let make_host_extern store (sink : sink ref) (memory_ref : W.Memory.t option ref) name =
  let need_memory () =
    match !memory_ref with
    | Some memory -> memory
    | None ->
      failwith "Loader: a host function was called before the guest's \"memory\" export was ready"
  in
  match name with
  | "log" ->
    W.Extern.func_as
      (W.Func.of_func_list ~args:[ Val.Kind.P Int32; P Int32 ] ~results:[] store (fun args ->
           match args with
           | [ Val.Int32 ptr; Val.Int32 len ] ->
             let memory = need_memory () in
             let s = W.Memory.to_string memory ~pos:ptr ~len in
             let req_w, _resp_r = relay_of_sink sink in
             Pipe_protocol.write_msg req_w ~tag:'L' (Bytes.of_string s);
             []
           | _ -> failwith "Loader: \"log\" called with unexpected argument shape"))
  | "read_materialized" ->
    (* (key_ptr, key_len, out_ptr) -> written_len (0 means "no value"). The guest supplies
       out_ptr as a buffer it owns and has sized large enough; this loader does not know or
       enforce that bound (a real allocator-aware protocol is future work -- see top comment). *)
    W.Extern.func_as
      (W.Func.of_func_list
         ~args:[ Val.Kind.P Int32; P Int32; P Int32 ]
         ~results:[ P Int32 ] store (fun args ->
           match args with
           | [ Val.Int32 key_ptr; Val.Int32 key_len; Val.Int32 out_ptr ] ->
             let memory = need_memory () in
             let merge_key = W.Memory.to_string memory ~pos:key_ptr ~len:key_len in
             let value =
               let req_w, resp_r = relay_of_sink sink in
               Pipe_protocol.write_msg req_w ~tag:'R' (Bytes.of_string merge_key);
               let flag = Pipe_protocol.read_frame resp_r in
               if Bytes.length flag = 1 && Bytes.get flag 0 = '\001' then
                 Some (Pipe_protocol.read_frame resp_r)
               else None
             in
             (match value with
             | None -> [ Val.Int32 0 ]
             | Some value ->
               write_guest_bytes memory ~ptr:out_ptr value;
               [ Val.Int32 (Bytes.length value) ])
           | _ -> failwith "Loader: \"read_materialized\" called with unexpected argument shape"))
  | "propose_write" ->
    (* (ptr, len) -> status (0 = Ok, 1 = Err; the guest is untrusted so the error string itself
       is not marshaled back, only the boolean outcome). *)
    W.Extern.func_as
      (W.Func.of_func_list ~args:[ Val.Kind.P Int32; P Int32 ] ~results:[ P Int32 ] store
         (fun args ->
           match args with
           | [ Val.Int32 ptr; Val.Int32 len ] ->
             let memory = need_memory () in
             let payload = read_guest_bytes memory ~ptr ~len in
             let ok =
               let req_w, resp_r = relay_of_sink sink in
               Pipe_protocol.write_msg req_w ~tag:'P' payload;
               let status = Pipe_protocol.read_frame resp_r in
               Bytes.length status = 1 && Bytes.get status 0 = '\000'
             in
             [ Val.Int32 (if ok then 0 else 1) ]
           | _ -> failwith "Loader: \"propose_write\" called with unexpected argument shape"))
  | other ->
    failwith (Printf.sprintf "Loader.instantiate: guest imports unrecognized host function %S" other)

let build_imports store sink memory_ref wasm =
  Wasm_binary.func_imports wasm
  |> List.map (fun (module_name, field_name) ->
         if module_name <> "host" then
           failwith
             (Printf.sprintf
                "Loader.instantiate: guest imports from unsupported module namespace %S (only \
                 \"host\" is supported)"
                module_name);
         make_host_extern store sink memory_ref field_name)

let find_memory export_positions exports =
  match Hashtbl.find_opt export_positions "memory" with
  | None -> None
  | Some idx -> ( try Some (W.Extern.as_memory (List.nth exports idx)) with _ -> None)

(* Real, instantiate-time enforcement of the brief's own "linear-memory page limit set at
   instantiation" (Step 3) -- the guest module's own self-declared max in its own WAT/wasm binary
   is under full guest control and enforces nothing against an adversarial module on its own;
   wasmtime's ordinary [memory.grow] semantics will happily honor a hostile guest's own
   multi-gigabyte self-declared maximum exactly as faithfully as a well-behaved one's small one.
   This rejects instantiation outright -- before the module ever runs -- for a declared maximum
   that exceeds [memory_pages_cap], or for a memory declared with no maximum at all (unbounded
   growth is itself a violation, not merely an unusually large but bounded one). A module
   declaring no local memory at all is unaffected here (nothing to cap); a missing "memory"
   export is [invoke]'s own, separate concern via [find_memory]. *)
let check_memory_limit wasm =
  match Wasm_binary.declared_memory_max_pages wasm with
  | None -> ()
  | Some None ->
    failwith
      (Printf.sprintf
         "Loader.instantiate: guest module declares its memory with no maximum at all \
          (unbounded growth) -- a declared maximum of at most %d pages (%d bytes) is required"
         memory_pages_cap
         (memory_pages_cap * 65536))
  | Some (Some declared_max) ->
    if declared_max > memory_pages_cap then
      failwith
        (Printf.sprintf
           "Loader.instantiate: guest module's own declared memory maximum (%d pages / %d bytes) \
            exceeds this loader's cap (%d pages / %d bytes)"
           declared_max (declared_max * 65536) memory_pages_cap (memory_pages_cap * 65536))

let instantiate ~tier ~module_bytes ~host ~protocol =
  match tier with
  | Microvm ->
    failwith "Loader.instantiate: Microvm tier is not yet implemented (Task 8's own job)"
  | Sfi ->
    let engine =
      W.Engine.create
        ~max_wasm_stack:(1 lsl 20) (* 1 MiB guest call-stack bound *)
        ()
    in
    let store = W.Store.create engine in
    let wasm_bytes = W.Wasmtime.wat_to_wasm ~wat:module_bytes in
    let wasm = W.Byte_vec.to_string wasm_bytes in
    check_memory_limit wasm;
    let modl = W.Wasmtime.new_module store ~wasm:wasm_bytes in
    let memory_ref = ref None in
    let sink = ref (Direct host) in
    let imports = build_imports store sink memory_ref wasm in
    let instance = W.Wasmtime.new_instance ~imports store modl in
    let exports = W.Instance.exports instance in
    let export_positions = Wasm_binary.export_positions wasm in
    let memory = find_memory export_positions exports in
    memory_ref := memory;
    let protocol_checker = ref (Protocol.start protocol) in
    { instance; exports; export_positions; memory; sink; protocol_checker }

(* The parent-side half of containment: services host-function relay requests from the child on
   [req_r]/[resp_w], and returns the child's own final result once it reports done -- via [tag]
   'D' (success, [payload] is the guest's own result bytes) or 'E' (the child's own [try...with]
   caught something and reported it as a clean failure). Every exit from this function -- success,
   fuel-timeout, a child that dies without ever completing a message (an uncaught OS signal --
   SIGSEGV/SIGABRT/SIGBUS from a Rust-side libwasmtime panic during real guest execution is a
   real, not hypothetical, way this can happen on this exact codebase, see this file's own top
   comment point 0), protocol corruption, OR an exception from [Unix.select] itself or from a
   host callback ('L'/'R'/'P' invoke entirely caller-supplied code this loader doesn't control) --
   reaps the child and closes both [req_r]/[resp_w] exactly once, via [cleanup], so {!invoke}'s
   own documented "never raises" contract genuinely holds no matter how the call ends.

   This took three real fix rounds to actually close, not one -- worth naming all three, since
   each subsequent one is exactly the kind of gap "the happy-path tests all pass, and so does
   the last regression test" hides. Round 1 fixed 2 of 5 *outcome* branches (an unrecognized
   pipe tag, or the child's write end closing before a complete message arrived) that skipped
   [cleanup] entirely. Round 2 fixed a deeper gap the first round's own [step] structure still
   had: only the [read_msg] call itself was guarded against exceptions -- the *surrounding*
   [Unix.select] call and the 'L'/'R'/'P' host-callback invocations were not, despite being just
   as capable of raising. Reproduced live by the code review, not theoretically: this test
   suite's own real, permanently-armed SIGALRM watchdog (`test_riptide.ml`'s per-test timeout)
   firing while genuinely blocked inside [Unix.select] raised an exception at that exact call
   site that escaped `invoke` uncaught, and the forked child (a runaway guest) was left orphaned
   to PID 1, still running at 100% CPU, confirmed live via `ps aux`.

   Round 3 fixed [cleanup] itself: wrapping the OUTER [step] in a try/with (round 2's fix) makes
   [step] as a whole exception-safe, but [cleanup]'s own body -- [kill]; [waitpid]; [close];
   [close] -- was not internally atomic against a SECOND asynchronous signal landing mid-sequence
   (e.g. between [kill] and [waitpid]). Since [cleaned_up] was set to [true] BEFORE that
   sequence ran, an interrupting exception at that point escaped uncaught (not a [Unix.Unix_error],
   so unaffected by round 2's [EINTR] handling) AND left [cleaned_up] already [true], so nothing
   ever retried the skipped [waitpid]/[close]/[close] -- a permanent zombie + 2 leaked fds, not
   just an escaped exception. Reproduced live by the code review (not theoretically): temporarily
   widened the kill-to-waitpid window with a sleep, fired SIGALRM repeatedly, watched the child
   become `<defunct>` via `ps --ppid`, confirmed the fds still open via `/proc/<pid>/fd`, then
   reverted the instrumentation. Fixed by masking every asynchronous signal
   ([signals_to_mask_during_cleanup]) around [cleanup]'s own sequence via [Unix.sigprocmask] --
   not by re-narrowing the guard again -- so a second signal is deferred, not lost, and by moving
   [cleaned_up := true] to run only once the whole sequence has actually completed, so even a
   genuinely unexpected (non-signal) failure mid-sequence leaves a clean, fully-idempotent state
   to retry from rather than a permanently-stuck "done" flag.

   Round 4 stopped narrowing and closed the CLASS. Round 3's masked attempt has a window of its
   own, strictly narrower than the one it closed but exactly the same shape: the instant between
   [cleanup] entering its own [try] and [Unix.sigprocmask SIG_BLOCK] actually taking hold. A
   signal landing THERE raised an exception that round 3's own outer catch-all swallowed -- so
   [cleaned_up] stayed [false], NONE of kill/waitpid/close/close had run, and, unlike rounds 1-3,
   nothing raised anywhere either: a permanent zombie plus 2 leaked fds sitting behind a
   perfectly normal-looking [Ok]/[Error], with no escaped exception to notice it by (which is how
   each of the first three was actually caught). Reproduced live by the code review the same way
   round 3's was -- widening that specific window with a temporary 50ms delay, ~10x this suite's
   own real 5ms SIGALRM interval, since unwidened it is nanoseconds wide and has no realistic
   production signal source at all (the fuel timeout is deadline+[select]-timeout based, not
   signal-based, and the only signal user anywhere in this codebase is the test suite's own
   watchdog) -- then confirmed the zombie and the still-open fds directly.

   The fix is deliberately NOT a fourth, narrower guard, because there is no reason to believe a
   fourth would be the last: every step of the sequence is already idempotent by design (re-kill
   hits ESRCH, re-wait hits ECHILD, re-close hits EBADF, all tolerated), and round 3 already made
   [cleaned_up := true] conditional on the whole sequence actually completing -- so the sequence
   is safe to simply RETRY, and "retry until [cleaned_up] is actually [true]" removes the notion
   of a window to find at all. Whatever instant a signal lands in, the only thing it can do is
   cost one wasted iteration: the loop re-enters and masks again, rather than silently giving up.
   Real signal delivery cannot be infinitely dense (an infinitely dense signal stream is a
   process that makes no progress at ALL, cleanup or otherwise), so an attempt eventually runs
   start-to-finish under the mask. Two supporting details, both load-bearing:
   - The mask is now restored from a value read by a PURE QUERY ([SIG_BLOCK] with an empty set
     changes nothing and returns the mask in effect), taken BEFORE [Fun.protect] is installed,
     with the actual [SIG_BLOCK] moved INSIDE it. Round 3 had this the other way round, which hid
     a second, quieter bug in the very same window: an exception between [SIG_BLOCK] returning and
     [Fun.protect] being installed left every asynchronous signal blocked in the process FOREVER
     (the restore was never armed, and the swallowed-then-retried-later mask read would then
     capture the already-blocked set as "previous"). A failed pure query, by contrast, changes no
     state at all -- so the retry loop genuinely starts each iteration from the caller's own mask.
   - [Out_of_memory]/[Stack_overflow] are still re-raised immediately and are never retried:
     looping on a process that is already out of resources is the one case where retrying is
     actively wrong, and OCaml convention is not to swallow either one regardless.
   The loop is a tail call, so even a pathologically signal-dense run costs no stack.

   All four rounds' regressions are pinned by `For_testing.simulate_child_death_mid_message`
   (round 1), `simulate_an_exception_mid_step` (round 2),
   `simulate_repeated_signals_during_cleanup` (round 3: a real, repeatedly-firing OS signal
   throughout an entire contained call, the same live-signal rigor the review's own
   reproduction used, without needing a permanent debug hook in production code), and
   `simulate_signal_in_cleanups_pre_mask_window` (round 4: the same real signal, landing in the
   specific pre-mask instant above, via a one-shot widening of exactly that window).

   One residual, disclosed rather than papered over (this file's own norm -- see the 1ms/5ms
   note on round 3's test): the OCaml runtime delivers a pending signal at its next polling
   point, and a function's own entry is such a point, so an exception can still be raised at
   [cleanup]'s entry BEFORE its own [try] is established -- no language construct can cover the
   instant before a handler is installed. That case changes no state whatsoever ([cleaned_up] is
   still [false], nothing has run), and every [cleanup] call site in this function is inside
   [step]'s single guard, whose handlers call [cleanup] again -- so it costs a retry from one
   level up, not a leak. Only two such deliveries back-to-back, in that same sub-instruction
   window, could escape [step] itself, and that escapes LOUDLY as an exception rather than
   silently as the leak this round closes. *)
let supervise_child ~child_pid ~req_r ~resp_w ~(sink : sink ref) () : (bytes, string) result =
  let host_of_sink () =
    match !sink with
    | Direct host -> host
    | Relay _ -> failwith "Loader: parent's own sink was unexpectedly switched to Relay"
  in
  let cleaned_up = ref false in
  let rec cleanup () =
    if not !cleaned_up then (
      (* ONE attempt. Every exception except the two below is swallowed here and then simply
         retried by the tail call at the bottom of this branch -- see this function's own doc
         comment (round 4) for why retrying, rather than adding a fourth narrower guard, is what
         actually closes this class: the attempt below is fully idempotent, and it sets
         [cleaned_up] only if it ran start to finish, so a signal landing in ANY instant of it
         (including the instant before its own mask takes hold, which no guard placed inside it
         can cover) costs one wasted iteration instead of silently abandoning a half-done
         kill/waitpid/close/close. Swallowing here also keeps [cleanup] itself non-raising for
         its callers, which is what lets [step] treat it as unconditionally safe on every one of
         its exit paths. *)
      (try
         (* Testing-only, one-shot, zero on every production path: widens the pre-mask window
            below so a real, repeatedly-firing signal can reliably be made to land in it. Reset
            BEFORE the delay, not after, so it is consumed exactly once even though the delay is
            expected to be interrupted by that very signal. *)
         if !pre_mask_window_widening_for_testing > 0. then (
           let delay = !pre_mask_window_widening_for_testing in
           pre_mask_window_widening_for_testing := 0.;
           Unix.sleepf delay);
         (* A PURE QUERY of the mask currently in effect ([SIG_BLOCK] with an empty set blocks
            nothing), taken before [Fun.protect] is installed precisely BECAUSE it changes no
            state: if this is the call an async signal interrupts, the process's mask is exactly
            as the caller left it and the retry above starts cleanly. The real [SIG_BLOCK] then
            happens INSIDE the protected body, so the window between "signals are now blocked"
            and "the restore is armed" does not exist at all -- round 3 had these two the other
            way round and could leave every async signal blocked in this process permanently.
            Everything below therefore runs with every asynchronous signal deferred (not lost),
            and the caller's own mask is always restored, however the body ends. *)
         let previous_mask = Unix.sigprocmask Unix.SIG_BLOCK [] in
         Fun.protect
           ~finally:(fun () -> ignore (Unix.sigprocmask Unix.SIG_SETMASK previous_mask))
           (fun () ->
             ignore (Unix.sigprocmask Unix.SIG_BLOCK signals_to_mask_during_cleanup);
             (* Harmless if the child already exited on its own (success/'E'/timeout already sent
                it a SIGKILL): killing an already-dead pid just raises ESRCH, tolerated below.
                Sending it unconditionally here, on every path, is exactly what makes this a
                single, uniform cleanup instead of the per-path duplication the original code had
                (and got wrong). *)
             (try Unix.kill child_pid Sys.sigkill with Unix.Unix_error _ -> ());
             (try ignore (Unix.waitpid [] child_pid) with Unix.Unix_error _ -> ());
             (try Unix.close req_r with Unix.Unix_error _ -> ());
             (try Unix.close resp_w with Unix.Unix_error _ -> ());
             (* Set only once the full sequence above has actually run to completion -- not
                before -- which is exactly what makes the retry above sound: every step is
                itself idempotent (re-killing/re-waiting/re-closing an already-handled resource
                just hits its own tolerated error), so a full retry from scratch is always safe,
                and an attempt that did NOT finish leaves nothing claiming it did. *)
             cleaned_up := true)
       with
       | (Out_of_memory | Stack_overflow) as exn ->
         (* Never retried and never swallowed: retrying anything is the wrong move for a process
            already out of memory or stack, and OCaml convention is to let both propagate. This
            is the ONLY way [cleanup] can raise. *)
         raise exn
       | _ -> ());
      (* Idempotent by construction: on the overwhelmingly common path the attempt above already
         set [cleaned_up], and this returns immediately without a second syscall. *)
      cleanup ())
  in
  (* MUTABLE, deliberately: it is extended by exactly the time the PARENT spends inside a host
     closure, so only genuine GUEST execution time is ever charged against the budget -- see
     [charge_to_host] below. *)
  let deadline = ref (Unix.gettimeofday () +. fuel_budget_seconds) in
  (* Final-fix-wave finding I2. The budget ([fuel_budget_seconds]) stands in for guest FUEL, i.e.
     work the guest itself does; but this parent's own supervision loop spends real wall-clock time
     running things that are not the guest at all. The 'L'/'R'/'P' arms below call entirely
     caller-supplied host closures ([host_functions]'s own three fields), and in this plan's own
     reactor (Task 6) a relayed [propose_write] genuinely drives a whole nested
     [Batch_commit.propose] -- authorization checkpoint, VSR commit, materialization, and every
     module dispatch that materialization itself retriggers -- before it returns. Throughout ALL of
     that the guest is blocked on the relay response, having executed nothing of its own since its
     call instruction.
     Charging that time against the guest produced a real, concrete misbehavior, not a theoretical
     unfairness: a well-behaved guest whose one host call happened to be slow (or merely deep) was
     SIGKILLed and reported "fuel exhausted" -- AFTER the write it proposed had already been
     authorized and committed by the very closure whose duration triggered the report. The caller
     then sees a containment failure for a call that in fact succeeded.
     So: stop the clock for the duration of every host-side call, by pushing the deadline out by
     exactly the elapsed host time. [Fun.protect] rather than a plain sequence, so the credit is
     applied even when the closure raises (in which case [step]'s own guard converts it to a
     containment failure and cleans up -- the deadline no longer matters, but leaving it
     inconsistent on one path and not another would be a trap for the next reader). The finally
     itself cannot raise (one [gettimeofday], one [ref] assignment), so no [Finally_raised] shape
     is reachable here.
     What this deliberately does NOT do is bound host-closure time: a host closure that blocks
     forever blocks this loop forever, exactly as it did before this fix. That is the caller's own
     code, on the caller's own (parent) process -- not the untrusted guest this loader is built to
     contain -- and giving it a deadline would mean this loader unilaterally deciding to abandon
     mid-flight an operation the caller may well have already made durable (a committed
     [Batch_commit.propose] is the concrete case). Disclosed as a real, bounded residual in
     [loader.mli]'s own {!invoke} contract rather than silently traded for the bug above; the
     reentrant-dispatch depth bound that keeps the nesting itself finite lives with the code that
     creates it, in [Reactor.max_dispatch_depth]. *)
  let charge_to_host : 'a. (unit -> 'a) -> 'a =
   fun f ->
    let started = Unix.gettimeofday () in
    Fun.protect ~finally:(fun () -> deadline := !deadline +. (Unix.gettimeofday () -. started)) f
  in
  (* One step of work: the fuel-deadline check, the [Unix.select] call, the [read_msg] that
     follows it, and dispatching whichever tag came back ('L'/'R'/'P' invoke the REAL host
     closures, which are entirely caller-supplied code this loader has no control over). Wrapped
     as ONE unit in a SINGLE exception guard below -- not per-call, not "just the read_msg", and
     not "everything except the deadline check" -- because ANY of it can raise, not just the
     read, and folding the deadline check in here too (rather than leaving it in [loop], guarded
     separately) means literally every [cleanup] call site in this function sits under the same
     guard, with no separate, easy-to-miss path left ungoverned. See this function's own doc
     comment above for the three real, live-reproduced gaps this closed, one per fix round. *)
  let step () : [ `Continue | `Done of (bytes, string) result ] =
    try
      let remaining = !deadline -. Unix.gettimeofday () in
      if remaining <= 0. then (
        cleanup ();
        `Done
          (Error
             (Printf.sprintf
                "Loader.invoke: fuel exhausted (wall-clock budget of %.1fs exceeded; the \
                 classic wasm_c_api this loader runs on has no fuel-metering API, see \
                 loader.ml's top comment -- the guest was SIGKILLed, not merely abandoned)"
                fuel_budget_seconds)))
      else
        match Unix.select [ req_r ] [] [] remaining with
        | [], _, _ -> `Continue (* spurious wakeup with time still left -- recompute and retry *)
        | _ -> (
          let tag, payload = Pipe_protocol.read_msg req_r in
          match tag with
          (* All three host-call arms run under [charge_to_host] (finding I2): the guest is blocked
             on its relayed call from the instant it issued it until this parent has finished both
             the closure AND the response write that unblocks it, so the whole arm -- not just the
             closure call inside it -- is host time, not guest time. *)
          | 'L' ->
            charge_to_host (fun () -> (host_of_sink ()).log (Bytes.to_string payload));
            `Continue
          | 'R' ->
            charge_to_host (fun () ->
                let merge_key = Bytes.to_string payload in
                match (host_of_sink ()).read_materialized ~merge_key with
                | None -> Pipe_protocol.write_frame resp_w (Bytes.make 1 '\000')
                | Some value ->
                  Pipe_protocol.write_frame resp_w (Bytes.make 1 '\001');
                  Pipe_protocol.write_frame resp_w value);
            `Continue
          | 'P' ->
            charge_to_host (fun () ->
                let status =
                  match (host_of_sink ()).propose_write payload with
                  | Ok () -> '\000'
                  | Error _ -> '\001'
                in
                Pipe_protocol.write_frame resp_w (Bytes.make 1 status));
            `Continue
          | 'D' ->
            cleanup ();
            `Done (Ok payload)
          | 'E' ->
            cleanup ();
            `Done (Error (Bytes.to_string payload))
          | other ->
            cleanup ();
            `Done
              (Error
                 (Printf.sprintf "Loader.invoke: internal containment-pipe protocol error (unrecognized tag %C)" other)))
    with
    | Unix.Unix_error (Unix.EINTR, _, _) ->
      (* A genuinely spurious interruption of the blocking syscall itself (as opposed to an
         OCaml-level signal handler raising something of its own, handled by the catch-all
         below) -- retry, not a failure. *)
      `Continue
    | (Out_of_memory | Stack_overflow) as exn ->
      (* These two are conventionally never silently caught-and-converted in OCaml -- they can
         indicate the process is already in a degraded state, and swallowing them here would
         hide that from the caller. [cleanup] is still attempted first (its own operations are
         cheap syscalls with minimal allocation, and leaving a zombie/leaked fds behind on the
         way out is its own real cost even when the process is about to report a more serious
         problem), but the exception itself is deliberately let through rather than converted to
         an ordinary [Error]. *)
      cleanup ();
      raise exn
    | exn ->
      cleanup ();
      `Done
        (Error
           (Printf.sprintf
              "Loader.invoke: the contained guest's process ended, or a host callback raised, \
               before completing its call (%s) -- treated as a containment failure, not a crash \
               of the host"
              (Printexc.to_string exn)))
  in
  let rec loop () = match step () with `Continue -> loop () | `Done result -> result in
  loop ()

(* Real containment for the (possibly-infinite) guest call: forks a genuine OS process to make
   it, relays any host-function calls the child makes back to the parent's real [host_functions]
   (via [t.sink], flipped to [Relay] only in the child -- see top comment), and (via
   [supervise_child] above) SIGKILLs the child if it hasn't finished within [fuel_budget_seconds].
   Returns the guest's own result BYTES on success, already read out of guest memory -- by the
   child itself, not the parent.

   That last part is load-bearing, not a style choice: guest linear memory is exactly as subject
   to copy-on-write as everything else fork duplicates. A first version of this function had the
   child send back the raw (result_ptr, result_len) pair and left `invoke` to read those bytes
   out of guest memory itself, in the parent, afterwards -- which is wrong for any non-empty
   result, since whatever the guest (or this loader's own [read_materialized]/[propose_write]
   host-closure implementations, which write their return values into guest memory) wrote during
   the call landed only in the *child's* private, post-fork copy of that memory page, never the
   parent's. Caught live by `test_read_materialized_relays_a_known_value_back_to_the_guest`
   (got 8 zero bytes back instead of "VALUE123" -- right length, since the ptr/len pair itself
   crossed the pipe fine, but the bytes at that address in the *parent's* memory view were never
   touched) and `test_propose_write_relays_the_hosts_denial_back_to_the_guest` (a status byte the
   guest itself wrote via `i32.store8` came back as the pre-call zero, not the guest's own
   write) -- both real regression tests now, not just a design note. *)
let run_contained t func ~memory ~arg_ptr ~arg_len : (bytes, string) result =
  let req_r, req_w = Unix.pipe ~cloexec:false () in
  let resp_r, resp_w = Unix.pipe ~cloexec:false () in
  match Unix.fork () with
  | 0 ->
    (* Child: never returns to the caller of [run_contained] -- always exits here. *)
    Unix.close req_r;
    Unix.close resp_w;
    t.sink := Relay { req_w; resp_r };
    (try
       match
         W.Wasmtime.func_call_list func [ Val.Int32 arg_ptr; Val.Int32 arg_len ] ~n_outputs:2
       with
       | [ Val.Int32 result_ptr; Val.Int32 result_len ] ->
         (* Read the result bytes HERE, in the child, while [memory] still reflects this
            process's own (possibly just-written-to) view of it -- see this function's own doc
            comment above for exactly why that matters. *)
         let result_bytes = W.Memory.to_string memory ~pos:result_ptr ~len:result_len in
         Pipe_protocol.write_msg req_w ~tag:'D' (Bytes.of_string result_bytes)
       | _ -> Pipe_protocol.write_msg req_w ~tag:'E' (Bytes.of_string "guest entrypoint did not return (ptr, len)")
     with
     | W.Trap { message } -> Pipe_protocol.write_msg req_w ~tag:'E' (Bytes.of_string message)
     | exn -> Pipe_protocol.write_msg req_w ~tag:'E' (Bytes.of_string (Printexc.to_string exn)));
    (* [_exit], not [exit]: skip OCaml's normal at_exit/GC-finalizer path in the child -- this
       process's whole job is done the instant its message is written, and running finalizers
       for wasmtime state this process only holds a copy-on-write view of is unnecessary risk
       for zero benefit (the parent independently owns and finalizes its own view). *)
    Unix._exit 0
  | child_pid ->
    Unix.close req_w;
    Unix.close resp_r;
    supervise_child ~child_pid ~req_r ~resp_w ~sink:t.sink ()

(* Exposed only so this task's own regression tests can prove {!invoke}'s "never raises, no
   zombie/fd leak" contract holds on the paths this loader cannot organically trigger through the
   public guest-execution API alone: [simulate_child_death_mid_message] (round 1's fix) -- a
   child that dies via an uncaught OS signal (or any other means that closes its pipe before a
   complete message is written) rather than through its own [try...with]; [simulate_an_exception_
   mid_step] (round 2's fix) -- an exception raised from inside [step] itself, whether from a
   host callback or from [Unix.select]'s own call site (what the code review's first live
   SIGALRM-watchdog reproduction looked like); and [simulate_repeated_signals_during_cleanup]
   (round 3's fix) -- a real, rapidly and repeatedly firing OS signal throughout an entire
   contained call, proving [cleanup] itself is safe against a SECOND signal landing mid-sequence
   (what the review's second live reproduction, widening the kill-to-waitpid window with a
   temporary sleep, looked like -- reproduced here without needing that same kind of permanent
   debug hook in production code); and [simulate_signal_in_cleanups_pre_mask_window] (round 4's
   fix) -- the same real signal, aimed at the one instant round 3's masking could not itself
   cover (after [cleanup] has entered its guard, before its [sigprocmask] has taken hold), via a
   one-shot widening of exactly that window, proving the retry loop recovers from it instead of
   silently abandoning a half-done cleanup. Not part of the guest-execution API -- Task 4/6 should
   never call any of these. *)
module For_testing = struct
  let simulate_child_death_mid_message () =
    let req_r, req_w = Unix.pipe ~cloexec:false () in
    let resp_r, resp_w = Unix.pipe ~cloexec:false () in
    match Unix.fork () with
    | 0 ->
      (* Deliberately closes its write end without ever sending a complete message -- from the
         parent's point of view this is indistinguishable from a signal-killed child: both leave
         the pipe closed with no full 'D'/'E' message pending. *)
      Unix.close req_r;
      Unix.close resp_w;
      Unix.close resp_r;
      Unix.close req_w;
      Unix._exit 0
    | child_pid ->
      Unix.close req_w;
      Unix.close resp_r;
      let sink =
        ref
          (Direct
             { read_materialized = (fun ~merge_key:_ -> None); propose_write = (fun _ -> Ok ()); log = ignore })
      in
      let result = supervise_child ~child_pid ~req_r ~resp_w ~sink () in
      result, child_pid, req_r, resp_w

  let simulate_an_exception_mid_step () =
    let req_r, req_w = Unix.pipe ~cloexec:false () in
    let resp_r, resp_w = Unix.pipe ~cloexec:false () in
    match Unix.fork () with
    | 0 ->
      (* Sends one real, well-formed 'L' (log) message, exactly what a genuine guest calling
         "log" produces -- the parent's own [step] dispatches it to the (caller-supplied) host
         closure below, which is where this test's own simulated failure actually happens; this
         child's only job is to trigger that dispatch. *)
      Unix.close req_r;
      Unix.close resp_w;
      Pipe_protocol.write_msg req_w ~tag:'L' (Bytes.of_string "boom");
      Unix.close resp_r;
      Unix.close req_w;
      Unix._exit 0
    | child_pid ->
      Unix.close req_w;
      Unix.close resp_r;
      let sink =
        ref
          (Direct
             {
               read_materialized = (fun ~merge_key:_ -> None);
               propose_write = (fun _ -> Ok ());
               (* Stands in for BOTH real failure modes this round's fix closes: a host closure
                  that itself raises (entirely caller-supplied code, e.g. Task 6's own reactor),
                  and an exception surfacing at the [Unix.select] call site itself (what the code
                  review's own SIGALRM-watchdog reproduction actually looked like) -- both are
                  handled by the exact same, now-unconditional exception guard around [step], so
                  exercising either one proves the fix for both. *)
               log = (fun _ -> failwith "simulated host-callback failure, mid-step");
             })
      in
      let result = supervise_child ~child_pid ~req_r ~resp_w ~sink () in
      result, child_pid, req_r, resp_w

  exception Injected_signal_for_testing

  let simulate_repeated_signals_during_cleanup () =
    let req_r, req_w = Unix.pipe ~cloexec:false () in
    let resp_r, resp_w = Unix.pipe ~cloexec:false () in
    match Unix.fork () with
    | 0 ->
      (* Sleeps briefly before closing its pipe without ever sending a complete message --
         giving the parent real wall-clock time inside both [Unix.select] and (once the pipe
         closes) [cleanup] itself for the rapidly, repeatedly firing signal armed below to
         actually land during both, not just have a theoretical chance to. *)
      Unix.close req_r;
      Unix.close resp_w;
      Unix.sleepf 0.02;
      Unix.close resp_r;
      Unix.close req_w;
      Unix._exit 0
    | child_pid ->
      Unix.close req_w;
      Unix.close resp_r;
      let sink =
        ref
          (Direct
             { read_materialized = (fun ~merge_key:_ -> None); propose_write = (fun _ -> Ok ()); log = ignore })
      in
      (* SIGALRM specifically, since it's a real, externally-armed signal this same test binary
         already relies on elsewhere (`test_riptide.ml`'s own suite-wide watchdog) -- reusing it
         here is what makes this a faithful, live reproduction of the review's own finding rather
         than a synthetic stand-in. Both the previous handler and the previous itimer are saved
         and restored exactly, regardless of how the protected call ends, specifically so this
         doesn't clobber that suite-wide watchdog's own armed state for whatever test runs next. *)
      let previous_handler =
        Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Injected_signal_for_testing))
      in
      (* 5ms, not something far more aggressive like 1ms: a first version of this test used a
         1ms interval and reliably SEGFAULTed, but only when run as part of the FULL suite (never
         in isolation, and never in a minimal standalone repro built to match this exact
         mask/fork/signal shape) -- strong circumstantial evidence it was hammering the OCaml
         runtime's own signal delivery hard enough to land inside a GC-triggered finalizer for
         some *unrelated*, already-created wasmtime object left over from an earlier test still
         awaiting collection (this test binary never touches wasmtime before `module_loader`'s
         own first test), rather than exposing anything about THIS loader's own [cleanup] logic
         specifically. That's a real, if narrower, fragility of OCaml signal handlers combined
         with ctypes-foreign's own dynamic-closure/finalizer machinery (this task already found
         two unrelated, genuine bugs in exactly that combination -- see this file's top comment
         point 0) -- worth knowing about, but out of THIS finding's own scope to chase further.
         5ms still fires several times within the child's 20ms sleep window (comfortably enough
         to reliably land inside both [Unix.select] and [cleanup] itself across repeated runs --
         verified live, 5/5 clean full-suite runs at this interval, vs. reliable reproduction of
         the SEGFAULT within the first 1-2 runs at 1ms) without reproducing that separate
         crash. *)
      let previous_itimer =
        Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.005; it_value = 0.005 }
      in
      Fun.protect
        ~finally:(fun () ->
          ignore (Unix.setitimer Unix.ITIMER_REAL previous_itimer);
          Sys.set_signal Sys.sigalrm previous_handler)
        (fun () ->
          let result = supervise_child ~child_pid ~req_r ~resp_w ~sink () in
          result, child_pid, req_r, resp_w)

  let simulate_signal_in_cleanups_pre_mask_window () =
    let req_r, req_w = Unix.pipe ~cloexec:false () in
    let resp_r, resp_w = Unix.pipe ~cloexec:false () in
    match Unix.fork () with
    | 0 ->
      (* Same shape as [simulate_child_death_mid_message]'s child: closes its write end without
         ever sending a complete message, which drives the parent straight into [step]'s
         exception path and from there into [cleanup] -- the function under test here. *)
      Unix.close req_r;
      Unix.close resp_w;
      Unix.close resp_r;
      Unix.close req_w;
      Unix._exit 0
    | child_pid ->
      Unix.close req_w;
      Unix.close resp_r;
      let sink =
        ref
          (Direct
             { read_materialized = (fun ~merge_key:_ -> None); propose_write = (fun _ -> Ok ()); log = ignore })
      in
      (* Real [SIGALRM] again, for the same reason round 3's test uses it (a faithful live
         reproduction of the review's own finding, with this same binary's own watchdog signal,
         rather than a synthetic stand-in), at the same 5ms interval (see the long note on that
         choice above -- 1ms reliably tripped a separate, unrelated ctypes-finalizer crash). *)
      let previous_handler =
        Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Injected_signal_for_testing))
      in
      let previous_itimer =
        Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.005; it_value = 0.005 }
      in
      (* The whole point of this test: 50ms of widening (10x the signal interval above, so the
         very first [cleanup] attempt is certain to be interrupted, not merely likely) injected
         into the ONE instant round 3's masking could not cover -- after [cleanup] has entered its
         own guard, before its [sigprocmask] has taken hold. One-shot, so the retry that follows
         runs unwidened and is expected to complete normally; with the retry loop removed, this
         same injection instead leaves a zombie child and two leaked fds behind a normal-looking
         result, which is exactly the failure round 4 closes (verified by reverting the loop). *)
      pre_mask_window_widening_for_testing := 0.05;
      Fun.protect
        ~finally:(fun () ->
          pre_mask_window_widening_for_testing := 0.;
          ignore (Unix.setitimer Unix.ITIMER_REAL previous_itimer);
          Sys.set_signal Sys.sigalrm previous_handler)
        (fun () ->
          let result = supervise_child ~child_pid ~req_r ~resp_w ~sink () in
          result, child_pid, req_r, resp_w)
end

(* Task 4: checked FIRST, before any export lookup/memory access/dispatch below -- a call the
   declared protocol doesn't permit from the checker's current state is rejected outright, with
   the guest never entered at all (not even far enough to discover it has no such export), per
   this codebase's own "guard failure => total no-op" convention (see [loader.mli]). On success,
   [t.protocol_checker] is advanced immediately, before the guest call actually runs -- the
   protocol governs which calls the guest is permitted to be DISPATCHED with, the same way a
   session type governs which message a peer is permitted to SEND; it isn't rolled back if the
   dispatched call then itself fails (traps, times out, etc.), the same way sending a legal
   message doesn't un-send itself just because its recipient then errors out handling it. *)
let invoke t ~entrypoint ~arg =
  match Protocol.step !(t.protocol_checker) ~call:entrypoint with
  | Error msg -> Error msg
  | Ok next_checker -> (
    t.protocol_checker := next_checker;
    match Hashtbl.find_opt t.export_positions entrypoint with
    | None -> Error (Printf.sprintf "Loader.invoke: no export named %S" entrypoint)
    | Some idx -> (
      match List.nth_opt t.exports idx with
      | None -> Error (Printf.sprintf "Loader.invoke: export %S has no matching extern" entrypoint)
      | Some extern -> (
        match t.memory with
        | None ->
          Error "Loader.invoke: guest module has no exported \"memory\", cannot marshal arg/result"
        | Some memory -> (
          match W.Extern.as_func extern with
          | exception _ ->
            Error (Printf.sprintf "Loader.invoke: export %S is not a function" entrypoint)
          | func -> (
            match
              (try
                 write_guest_bytes memory ~ptr:arg_scratch_offset arg;
                 Ok ()
               with exn -> Error (Printexc.to_string exn))
            with
            | Error msg -> Error msg
            | Ok () ->
              run_contained t func ~memory ~arg_ptr:arg_scratch_offset ~arg_len:(Bytes.length arg)))))
    )
