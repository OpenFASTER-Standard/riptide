type t = { value : Riptide.Value.value; timestamp : int64 }
include Lattice_intf.S with type t := t
