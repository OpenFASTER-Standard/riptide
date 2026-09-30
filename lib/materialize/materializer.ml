(* Deliberately declared HERE, outside [Make]'s functor body, not nested inside it: [Make] is a
   generative functor (OCaml's default), so an exception constructor declared inside its body
   would be a genuinely DIFFERENT type per application -- unusable by a caller like
   [Riptide_batch_commit.Batch_commit] that only ever sees an erased [materialize_sink] closure
   and never the concrete [L]/[KV] a given [Materializer.t] was built with (see
   [materializer.mli]'s own [materialize_sink] doc for why that erasure exists). One shared,
   top-level exception, exactly the precedent {!Riptide_vsr.Replica.Sender_mismatch} already sets
   in lib/vsr/replica.ml/.mli (declared at the module's own top level, not nested inside anything
   generic), is what makes it possible for a caller to catch this ONE specific failure shape by
   name, regardless of which lattice/KV backend raised it. See [write]'s own doc comment in the
   [.mli] for why this exists and exactly what it does and does not catch. *)
exception Value_too_large of string

module Make (L : Riptide_lattice.Lattice_intf.S) (KV : Riptide_storage.Kv_store_intf.S) = struct
  type t = {
    kv : KV.t;
    decode : string -> L.t;
    encode : L.t -> string;
    locks : (string, Eio.Mutex.t) Hashtbl.t;
        (* Task 20: one [Eio.Mutex.t] per [merge_key] ever written through THIS [t], created
           lazily by [mutex_for] and never removed -- see [mutex_for]'s own comment for why the
           lazy lookup-or-create itself needs no lock of its own, and [materializer.mli]'s [write]
           doc for the guarantee this buys and exactly how far it extends. *)
  }

  let create ~kv ~owner ~decode ~encode =
    let actual = KV.owner kv in
    if actual <> owner then
      invalid_arg
        (Printf.sprintf "Materializer.create: kv is owned by %S, expected %S" actual owner);
    { kv; decode; encode; locks = Hashtbl.create 16 }

  let read t ~merge_key =
    match KV.get t.kv ~key:merge_key with
    | None -> L.bottom
    | Some s -> t.decode s

  (* Task 20: look up [merge_key]'s mutex, creating it on first use. Two fibers racing to be the
     first writer of a never-before-seen [merge_key] can never each create and insert their OWN
     mutex (which would defeat the whole fix -- they'd hold different locks and still race the
     way [write] used to). This is verified directly against Eio's own single-domain, cooperative
     scheduling semantics (per [Eio.Fiber]'s own documentation: within a domain, only one fiber
     runs at a time, and a fiber is only suspended in favor of another when it performs an
     operation that can block): [Hashtbl.find_opt] and [Hashtbl.replace] below do no I/O and
     contain no such operation, so whichever fiber reaches this function first runs the whole
     find-then-maybe-create-then-insert sequence to completion before any other fiber gets a
     chance to run -- there is no window in which a second fiber could observe [None] for a key the
     first fiber has already decided to create a mutex for but not yet inserted. (This reasoning
     is specific to a single OS domain; it would not hold if a future caller ran multiple Eio
     domains against one shared [t], which nothing in this codebase does today.)

     [Hashtbl.replace], not [Hashtbl.add], for the insert: correctness here depends entirely on
     the invariant above (two fibers never both reach the [None] branch for the same key) holding
     perfectly. [replace] makes an accidental future violation of that invariant idempotent --
     the second insert just overwrites the first with an equivalent, freshly-created mutex --
     instead of [add]'s behavior of leaving both bindings present with the old one shadowed,
     which would silently waste a mutex but otherwise still work by luck today, and be a much
     more confusing bug to chase if it ever didn't. *)
  let mutex_for t ~merge_key =
    match Hashtbl.find_opt t.locks merge_key with
    | Some mutex -> mutex
    | None ->
      let mutex = Eio.Mutex.create () in
      Hashtbl.replace t.locks merge_key mutex;
      mutex

  let write t ~merge_key value =
    (* [use_ro], not [use_rw]: [KV.put] can raise (e.g. {!Riptide_storage.File_kv_store}'s
       documented size-cap [Invalid_argument]) without having written anything -- the
       [merge_key]'s stored value is left exactly as it was, a consistent state despite the
       exception, which is exactly the case [use_ro] (unlock and re-raise) is for. [use_rw] would
       instead permanently disable this [merge_key]'s mutex on that same exception, contradicting
       [materializer.mli]'s existing, deliberately-unfixed documentation that a subsequent
       SMALLER write to the same [merge_key] must go on succeeding. *)
    Eio.Mutex.use_ro (mutex_for t ~merge_key) (fun () ->
        let current = read t ~merge_key in
        let merged = L.join current value in
        (* [decode] (inside [read]), [L.join], and [t.encode] above are all deliberately OUTSIDE
           this catch -- only the [KV.put] call itself is wrapped, and only for [Invalid_argument]
           specifically. A caller's own [encode] can raise [Invalid_argument] for reasons that have
           nothing to do with the KV backend's size cap (e.g. {!Riptide.Value.canonical_encode}'s
           own documented duplicate-Record/Map-key rejection, lib/value.ml) -- a genuine
           value-layer contract violation that must propagate as a plain, uncaught
           [Invalid_argument], not be laundered into "the size cap fired". This mirrors
           {!Riptide_vsr.Replica.durable_append}'s own precedent in lib/vsr/replica.ml (its own
           comment: "[Value.canonical_encode] is evaluated OUTSIDE the handler on purpose"):
           evaluate everything that can raise for an UNRELATED reason before entering the narrow
           try, so only the one specific, documented call is ever caught here. *)
        let encoded = t.encode merged in
        match KV.put t.kv ~key:merge_key encoded with
        | () -> ()
        | exception Invalid_argument msg -> raise (Value_too_large msg))
end
