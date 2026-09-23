(* See fault_injecting_storage.mli for the full design rationale. Summary of the one tricky bit:
   [t] wraps an arbitrary [Storage_intf.S]-conforming module + its own value together, which OCaml
   modules can't express as an ordinary record field (the module's own [t] is a different type per
   instantiation) -- so [t] is a GADT with one constructor that existentially quantifies over that
   type, following the standard OCaml idiom for "a first-class module plus a value of its abstract
   type, packaged so the type variable doesn't leak into this module's own [t]". *)

module Int_set = Set.Make (Int) (* same local convention as lib/vsr/replica.ml's own recv_svc *)

type fault_config = { drop_probability : float; corrupt_probability : float }

let default_fault_config = { drop_probability = 0.0; corrupt_probability = 0.0 }

type t =
  | T : {
      module_ : (module Storage_intf.S with type t = 'a);
      value : 'a;
      prng : Riptide_sim.Prng.t;
      fault_config : fault_config;
      faults_max : int;
      mutable corrupted_slots : Int_set.t;
          (* op_numbers this module has itself corrupted and that haven't since been truncated
             away -- see the .mli's [create] doc comment for why this is a conservative, not
             exact, count once the wrapped backend's own eviction (e.g. ring wraparound) is in
             play. *)
    }
      -> t

let create (type a) ~prng ?(fault_config = default_fault_config) ~replication_quorum
    ~underlying:(module U : Storage_intf.S with type t = a) (value : a) =
  T
    { module_ = (module U : Storage_intf.S with type t = a);
      value;
      prng;
      fault_config;
      faults_max = replication_quorum - 1;
      corrupted_slots = Int_set.empty
    }

(* XOR-flips one deterministically-chosen byte of [data], content-seeded via
   [Prng.int prng (String.length data)] -- so which byte gets flipped depends on both [prng]'s
   current draw and [data]'s own length, and (since this is only ever called once, at write time,
   never re-invoked against the same entry on a later read) the corruption is permanent: nothing
   about a later [wal_read] retries this decision or could possibly find the entry "healed".
   A no-op for an empty string -- there is no byte to flip. *)
let flip_one_byte prng data =
  let len = String.length data in
  if len = 0 then data
  else begin
    let pos = Riptide_sim.Prng.int prng len in
    let bytes = Bytes.of_string data in
    Bytes.set bytes pos (Char.chr (Char.code (Bytes.get bytes pos) lxor 0xFF));
    Bytes.unsafe_to_string bytes
  end

let wal_append (T r) ~op_number data =
  let module U = (val r.module_) in
  (* Fault decisions are always drawn in the same order regardless of which branch is taken, so
     the sequence of draws from [r.prng] depends only on the sequence of [wal_append] calls, not
     on which faults happened to fire along the way -- matching [Network.schedule]'s own
     discipline of drawing every fault decision unconditionally at the point of the call. *)
  let dropped = Riptide_sim.Prng.bool r.prng r.fault_config.drop_probability in
  let corrupt = Riptide_sim.Prng.bool r.prng r.fault_config.corrupt_probability in
  if dropped then
    (* Silently never delegated: the wrapped backend's own [wal_highest_op_number] does not
       advance, and a later [wal_read t ~op_number] is [None] -- see the .mli's [drop_probability]
       doc comment. *)
    ()
  else if corrupt && String.length data > 0 then begin
    if Int_set.cardinal r.corrupted_slots >= r.faults_max then
      invalid_arg "faults_max exceeded"
    else begin
      U.wal_append r.value ~op_number (flip_one_byte r.prng data);
      r.corrupted_slots <- Int_set.add op_number r.corrupted_slots
    end
  end
  else U.wal_append r.value ~op_number data

(* A corrupted slot always reads as [None] from *this* [t], regardless of what the wrapped
   backend's own checksum machinery thinks -- and deliberately does not rely on that machinery to
   agree. [flip_one_byte]'s output is still fully self-consistent by the time it reaches [U]:
   [U.wal_append] computes its own checksum from exactly the (already-flipped) bytes it receives,
   so a real [Storage_intf.S] implementation like [File_storage] (which has no way to know the
   bytes it was handed differ from what the caller "really" meant) durably stores a checksum that
   matches the corrupted data and would happily hand it back as [Some corrupted_data] on its own.
   [corrupted_slots] is what actually makes the corruption externally observable as [None] here --
   the byte flip itself only matters for what ends up durably on disk (relevant to a later reader
   that bypasses this wrapper entirely, e.g. a differently-implemented recovery path), not for
   this wrapper's own [wal_read]. *)
let wal_read (T r) ~op_number =
  if Int_set.mem op_number r.corrupted_slots then None
  else
    let module U = (val r.module_) in
    U.wal_read r.value ~op_number

let wal_truncate_after (T r) ~op_number =
  let module U = (val r.module_) in
  U.wal_truncate_after r.value ~op_number;
  r.corrupted_slots <- Int_set.filter (fun n -> n <= op_number) r.corrupted_slots

let wal_highest_op_number (T r) =
  let module U = (val r.module_) in
  U.wal_highest_op_number r.value

let superblock_write (T r) data =
  let module U = (val r.module_) in
  U.superblock_write r.value data

let superblock_read (T r) =
  let module U = (val r.module_) in
  U.superblock_read r.value
