module Make (L : Riptide_lattice.Lattice_intf.S) (KV : Riptide_storage.Kv_store_intf.S) : sig
  type t
  val create : kv:KV.t -> decode:(string -> L.t) -> encode:(L.t -> string) -> t
  val write : t -> merge_key:string -> L.t -> unit
  val read : t -> merge_key:string -> L.t
end
