module Make (L : Riptide_lattice.Lattice_intf.S) (KV : Riptide_storage.Kv_store_intf.S) = struct
  type t = { kv : KV.t; decode : string -> L.t; encode : L.t -> string }

  let create ~kv ~decode ~encode = { kv; decode; encode }

  let read t ~merge_key =
    match KV.get t.kv ~key:merge_key with
    | None -> L.bottom
    | Some s -> t.decode s

  let write t ~merge_key value =
    let current = read t ~merge_key in
    let merged = L.join current value in
    KV.put t.kv ~key:merge_key (t.encode merged)
end
