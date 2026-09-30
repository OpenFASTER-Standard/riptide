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

type t = { subscriptions : (string, subscription list) Hashtbl.t }

let create () = { subscriptions = Hashtbl.create 16 }

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
        | Some subs -> List.iter (fun sub -> dispatch ~merge_key sub v) subs);
  }
