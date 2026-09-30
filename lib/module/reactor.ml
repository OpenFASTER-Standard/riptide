(* Reactor dispatch loop (Task 6, subtasks 6.1 + 6.5). See reactor.mli's own top comment for the
   overall shape; this file is deliberately small -- it wires Tasks 1-5's own already-real
   machinery together rather than inventing anything new. *)

type subscription = {
  module_ : Admission.verified_artifact;
  protocol : Protocol.t;
  read : merge_key:string -> bytes option;
  propose : bytes -> (unit, string) result;
  (* Read once, at subscribe time, from [module_.local_path] -- see reactor.mli's own [subscribe]
     doc comment for why this is deliberate rather than re-reading on every dispatch. *)
  module_bytes : string;
}

type t = {
  subscriptions : (string, subscription list) Hashtbl.t;
  (* How many of this reactor's own dispatches are currently live on the stack, one per nesting
     level -- see [max_dispatch_depth] and [wrap_materialize_sink]. Not a total dispatch count:
     incremented on entry to a fan-out and decremented on the way out, so at steady state (nothing
     dispatching) it is 0. *)
  mutable dispatch_depth : int;
}

let create () = { subscriptions = Hashtbl.create 16; dispatch_depth = 0 }

(* Final-fix-wave finding I1: the hard ceiling on REENTRANT dispatch nesting.

   Dispatch is genuinely reentrant, and that is by design, not by accident: a dispatched module's
   own [propose_write] is wired (by the caller) to a real [Batch_commit.propose], which commits,
   materializes, and drives the very sink that dispatched it -- so a module whose output lands on
   its own subscribed key retriggers itself, which is exactly the cascade
   test_module_end_to_end.ml exercises for real (4 dispatches, 3 of them retriggers, all nested).
   Nothing bounded that nesting, and the resource cost per level is not small: every level holds a
   live forked child process ([Loader.invoke]'s containment), two pipe file descriptors, and a
   freshly compiled WASM instance, all of them alive until the level below it returns. A guest that
   unconditionally proposes to its own key therefore consumed processes and descriptors without
   limit, in a loop nothing in this codebase could stop -- an unbounded resource-exhaustion hazard
   reachable from (admitted, but still untrusted) guest code alone.

   8 is chosen, not derived: deliberately well above the deepest cascade anything in this repo
   actually performs (4, in test_module_end_to_end.ml's real end-to-end chain) so a legitimate
   multi-step reaction chain has real headroom, and well below any level at which N live children +
   2N descriptors is itself a problem. Its relation to [Loader.fuel_budget_seconds] is worth stating
   explicitly, because it CHANGED in this same fix wave: before finding I2 was fixed, nested time
   was charged against every outer level's own guest-fuel budget, so deep nesting was crudely
   self-limiting -- an outer guest would eventually be SIGKILLed as a "runaway" (wrongly, which is
   exactly the bug I2 fixed) and the chain would collapse from the outside in. Now that only real
   guest time counts against that budget, nothing self-limits, and this bound is the ONLY thing
   keeping the nesting finite. It is load-bearing, not belt-and-braces.

   What this deliberately is NOT: a scheduler. The proper mechanism -- queue a retriggered dispatch
   rather than recursing into it, so a legitimately deep reaction chain runs to completion at depth
   1 -- needs a real design (ordering, fairness, durability across restarts, and what it means for
   the sequential-dispatch contract [wrap_materialize_sink] documents), which is future-task
   material per this project's own decomposition discipline, not something to freelance here. This
   converts an unbounded hazard into a bounded, clearly-reported, disclosed limit; it does not
   pretend to be the mechanism that makes the limit unnecessary. *)
let max_dispatch_depth = 8

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let subscribe t ~merge_key ~module_ ~protocol ~read ~propose =
  let module_bytes = read_file module_.Admission.local_path in
  let sub = { module_; protocol; read; propose; module_bytes } in
  let existing = Option.value (Hashtbl.find_opt t.subscriptions merge_key) ~default:[] in
  Hashtbl.replace t.subscriptions merge_key (existing @ [ sub ])

(* Process-lifetime, monotonic -- see reactor.mli's own [For_testing.log_call_count] doc comment
   for why this shape (never reset, delta-read) rather than a per-call return value. *)
let log_calls = ref 0

module For_testing = struct
  let log_call_count () = !log_calls
end

(* One subscribed module's own dispatch for one materialized change -- isolated from every other
   subscribed module's own dispatch (see reactor.mli's top comment): any failure here, whether
   raised by Loader.instantiate itself (a setup-time Failure) or returned as an Error by
   Loader.invoke (a protocol violation, a trap, a fuel timeout), is caught and logged, never
   propagated to wrap_materialize_sink's own caller and never allowed to stop a sibling
   subscription (on this key or any other) from running.

   [Out_of_memory]/[Stack_overflow] are the two exceptions to that catch-all, deliberately: they
   indicate the process ITSELF is in trouble, not a normal per-module failure to log and move past
   -- matching loader.ml's own [cleanup] precedent in this exact codebase (see its own doc comment)
   rather than silently converting them to an ordinary logged-and-ignored failure. [Loader.invoke]
   itself never raises these (it returns [Error]), so today's practical exposure is narrow, but the
   catch-all here should still match the same established pattern, not a narrower one of its own. *)
let dispatch ~merge_key sub (v : Riptide.Value.value) =
  (* Identifies which subscription a given log line came from -- both the guest's own relayed
     "log" calls and this function's own dispatch-failure/dispatch-raised messages -- since
     nothing in the log stream otherwise distinguishes one subscriber's output from a sibling's,
     including two subscribers sharing the same merge_key (exactly the fan-out shape this reactor
     exists for). *)
  let context =
    Printf.sprintf "merge_key=%S module=%S" merge_key sub.module_.Admission.local_path
  in
  try
    let host =
      {
        Loader.read_materialized = sub.read;
        propose_write = sub.propose;
        log =
          (fun s ->
            incr log_calls;
            Printf.eprintf "[reactor %s] module log: %s\n%!" context s);
      }
    in
    let m =
      Loader.instantiate ~tier:sub.module_.Admission.tier ~module_bytes:sub.module_bytes ~host
        ~protocol:sub.protocol
    in
    match
      Loader.invoke m ~entrypoint:"handle" ~arg:(Bytes.of_string (Riptide.Value.canonical_encode v))
    with
    | Ok (_ : bytes) -> ()
    | Error msg -> Printf.eprintf "[reactor %s] module dispatch failed: %s\n%!" context msg
  with
  | (Out_of_memory | Stack_overflow) as exn -> raise exn
  | exn -> Printf.eprintf "[reactor %s] module dispatch raised: %s\n%!" context (Printexc.to_string exn)

let wrap_materialize_sink t (inner : Riptide_batch_commit.Batch_commit.materialize_sink) :
    Riptide_batch_commit.Batch_commit.materialize_sink =
  {
    write =
      (fun ~merge_key v ->
        inner.write ~merge_key v;
        match Hashtbl.find_opt t.subscriptions merge_key with
        | None -> ()
        | Some subs ->
          (* Finding I1's bound (see [max_dispatch_depth] for the full reasoning, including why it
             is now the ONLY thing keeping reentrant nesting finite). Checked AFTER [inner.write]
             above, never instead of it: hitting this limit must never be a reason materialization
             itself gets skipped, delayed or reordered -- that guarantee is unconditional (see
             reactor.mli). Refusing is logged and otherwise treated exactly like a module that chose
             to do nothing this dispatch, not raised: the caller that would receive such an
             exception is the guest's own relayed [propose_write] host call one level up, which has
             no way to act on it, and raising there would convert one module's excess nesting into a
             failure of an unrelated sibling's already-in-flight call. *)
          if t.dispatch_depth >= max_dispatch_depth then
            Printf.eprintf
              "[reactor merge_key=%S] refusing to dispatch: maximum reentrant dispatch depth (%d) \
               is already live -- a subscribed module's own proposal retriggering its own key, \
               see Reactor.max_dispatch_depth\n\
               %!"
              merge_key max_dispatch_depth
          else begin
            t.dispatch_depth <- t.dispatch_depth + 1;
            Fun.protect
              ~finally:(fun () -> t.dispatch_depth <- t.dispatch_depth - 1)
              (fun () -> List.iter (fun sub -> dispatch ~merge_key sub v) subs)
          end);
  }
