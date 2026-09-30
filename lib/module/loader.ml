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

(* Which side of a possible fork a host-import closure is currently running on. [Direct] calls
   the caller-supplied [host_functions] straight (the normal, non-contained path, and always
   what the *parent* process uses). [Relay] is switched to only inside a just-forked *child*
   (see [run_contained]) -- copy-on-write means mutating this ref in the child never touches the
   parent's own copy, so the parent's host functions keep working normally, untouched by
   whatever the child does with its own private copy of this same ref cell. *)
type sink = Direct of host_functions | Relay of { req_w : Unix.file_descr; resp_r : Unix.file_descr }

type t = {
  instance : W.Instance.t;
  exports : W.Extern.t list;
  export_positions : (string, int) Hashtbl.t;
  memory : W.Memory.t option;
  sink : sink ref;
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

  (* `limits ::= 0x00 min:u32 | 0x01 min:u32 max:u32` -- shared by table/memory descriptors. *)
  let skip_limits s pos =
    let flag, pos = read_u8 s pos in
    let _min, pos = read_uleb32 s pos in
    if flag land 1 = 1 then snd (read_uleb32 s pos) else pos

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
     Raises on a table/memory/global import (not supported by this task's host ABI; those kinds
     are still correctly skipped over structurally so later entries parse right, they're just
     never turned into an extern for the caller). *)
  let func_imports wasm : (string * string) list =
    let acc = ref [] in
    iter_sections wasm ~f:(fun id s pos ->
        if id = 2 (* import section *) then (
          let count, pos = read_uleb32 s pos in
          let rec loop i pos =
            if i >= count then ()
            else
              let module_name, pos = read_name s pos in
              let field_name, pos = read_name s pos in
              let kind, pos = read_u8 s pos in
              let pos =
                match kind with
                | 0 (* func *) -> snd (read_uleb32 s pos (* typeidx *))
                | 1 (* table *) ->
                  let _elemtype, pos = read_u8 s pos in
                  skip_limits s pos
                | 2 (* memory *) -> skip_limits s pos
                | 3 (* global *) ->
                  let _valtype, pos = read_u8 s pos in
                  let _mut, pos = read_u8 s pos in
                  pos
                | k ->
                  failwith
                    (Printf.sprintf "Loader.instantiate: guest module imports unsupported kind %d" k)
              in
              if kind = 0 then acc := (module_name, field_name) :: !acc;
              loop (i + 1) pos
          in
          loop 0 pos));
    List.rev !acc
end

(* Stands in for wasmtime's own per-instruction fuel metering (unavailable on the classic
   wasm_c_api this loader runs on -- see top comment point 1). Generous relative to any test
   fixture's real work (a single host call), far below "looks hung" to a human running
   `dune test`. *)
let fuel_budget_seconds = 2.0

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
             (match !sink with
             | Direct host -> host.log s
             | Relay { req_w; _ } -> Pipe_protocol.write_msg req_w ~tag:'L' (Bytes.of_string s));
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
               match !sink with
               | Direct host -> host.read_materialized ~merge_key
               | Relay { req_w; resp_r } ->
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
               match !sink with
               | Direct host -> Result.is_ok (host.propose_write payload)
               | Relay { req_w; resp_r } ->
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

let instantiate ~tier ~module_bytes ~host =
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
    let modl = W.Wasmtime.new_module store ~wasm:wasm_bytes in
    let memory_ref = ref None in
    let sink = ref (Direct host) in
    let imports = build_imports store sink memory_ref wasm in
    let instance = W.Wasmtime.new_instance ~imports store modl in
    let exports = W.Instance.exports instance in
    let export_positions = Wasm_binary.export_positions wasm in
    let memory = find_memory export_positions exports in
    memory_ref := memory;
    { instance; exports; export_positions; memory; sink }

(* Real containment for the (possibly-infinite) guest call: forks a genuine OS process to make
   it, relays any host-function calls the child makes back to the parent's real [host_functions]
   (via [t.sink], flipped to [Relay] only in the child -- see top comment), and SIGKILLs the
   child if it hasn't finished within [fuel_budget_seconds]. Returns the guest's own result BYTES
   on success, already read out of guest memory -- by the child itself, not the parent.

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
    let host_of_sink () =
      match !(t.sink) with
      | Direct host -> host
      | Relay _ -> failwith "Loader: parent's own sink was unexpectedly switched to Relay"
    in
    let deadline = Unix.gettimeofday () +. fuel_budget_seconds in
    let finish result =
      Unix.close req_r;
      Unix.close resp_w;
      result
    in
    let rec loop () =
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0. then (
        (try Unix.kill child_pid Sys.sigkill with Unix.Unix_error _ -> ());
        ignore (Unix.waitpid [] child_pid);
        finish
          (Error
             (Printf.sprintf
                "Loader.invoke: fuel exhausted (wall-clock budget of %.1fs exceeded; the \
                 classic wasm_c_api this loader runs on has no fuel-metering API, see \
                 loader.ml's top comment -- the guest was SIGKILLed, not merely abandoned)"
                fuel_budget_seconds)))
      else
        match Unix.select [ req_r ] [] [] remaining with
        | [], _, _ -> loop () (* spurious wakeup with time still left -- recompute and retry *)
        | _ -> (
          let tag, payload = Pipe_protocol.read_msg req_r in
          match tag with
          | 'L' ->
            (host_of_sink ()).log (Bytes.to_string payload);
            loop ()
          | 'R' ->
            let merge_key = Bytes.to_string payload in
            (match (host_of_sink ()).read_materialized ~merge_key with
            | None -> Pipe_protocol.write_frame resp_w (Bytes.make 1 '\000')
            | Some value ->
              Pipe_protocol.write_frame resp_w (Bytes.make 1 '\001');
              Pipe_protocol.write_frame resp_w value);
            loop ()
          | 'P' ->
            let status =
              match (host_of_sink ()).propose_write payload with Ok () -> '\000' | Error _ -> '\001'
            in
            Pipe_protocol.write_frame resp_w (Bytes.make 1 status);
            loop ()
          | 'D' ->
            ignore (Unix.waitpid [] child_pid);
            finish (Ok payload)
          | 'E' ->
            ignore (Unix.waitpid [] child_pid);
            finish (Error (Bytes.to_string payload))
          | other -> failwith (Printf.sprintf "Loader: unknown internal pipe tag %C" other))
    in
    loop ()

let invoke t ~entrypoint ~arg =
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
