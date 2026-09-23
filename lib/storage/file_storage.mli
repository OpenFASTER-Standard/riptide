(** A [Storage.S] backend: a fixed-size ring WAL with redundant, physically-separate headers
    (op_number/length/checksum), backed by real [O_DIRECT]+[O_DSYNC]-durable writes via
    [eio_linux]'s low-level [io_uring] API where the underlying filesystem supports it, falling
    back to [O_DSYNC] alone automatically where it doesn't. See
    {!Riptide_storage.File_storage}'s own [.ml] top comment for: the exact on-disk ring/header
    layout; why Task 1's version of this module had to drop [O_DIRECT] (a shared fixed-buffer
    pool with no alignment guarantee); and how this version makes [O_DIRECT] work for real (a
    self-allocated, [mmap]-backed, guaranteed-page-aligned buffer per read/write, validated with
    2500 real operations across both an ext4 and an overlayfs mount with zero failures). *)

include Storage_intf.S

val create :
  sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> ring_capacity:int -> string -> t
(** [create ~sw ~fs ~ring_capacity dir_path] opens (creating if necessary) a ring WAL directory
    at [dir_path]. [ring_capacity] is the number of fixed-size slots the ring holds
    -- [wal_append] of op_number [n] overwrites whatever was previously at op_number
    [n - ring_capacity], if anything.

    {b [ring_capacity] is REQUIRED, with no default}, which is a deliberate change (final-review
    finding I4): it used to default to [8]. Overwriting op_number [n - ring_capacity] means
    silently destroying an entry this module's own [wal_append] already promised was durable, and
    nothing in this system ever truncates a committed prefix away (there is no checkpointing), so
    every entry stays live forever and a log longer than the ring destroys committed,
    client-acknowledged data with no signal to any caller. The protocol-level consequence is
    total and needs no injected faults — see [test/test_dst_scenarios.ml]'s own ring-capacity
    boundary test, which reproduces a permanently wedged cluster past the bound. Pairing that with
    a small, invisible default was backwards; raising the default would only have made it a
    less-likely-to-bite invisible default. A caller must now state the bound it is accepting.

    [wal_highest_op_number] is recovered by scanning every slot's header (and validating each
    one's checksum against that slot's own data) on [dir_path] as it already exists on disk, so
    reopening the same directory after a process restart picks up exactly where the previous
    process left off, including across ring wraparound.

    [File_storage]-specific limitation, not part of the abstract {!Storage_intf.S} contract:
    [wal_append] raises [Invalid_argument] for any entry larger than one aligned data slot
    (currently 4096 bytes), since each slot holds exactly one entry's data, zero-padded to the
    slot's fixed size. *)
