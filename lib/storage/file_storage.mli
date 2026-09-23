(** A one-WAL-entry-per-file [Storage.S] backend, backed by real [O_DSYNC]-durable writes via
    [eio_linux]'s low-level [io_uring] API. Task 2 replaces the one-file-per-entry layout with a
    real fixed-size ring; this module exists only to prove the underlying
    durable-write-then-read-after-restart primitive works for real against this box's actual
    installed toolchain. See {!Riptide_storage.File_storage}'s own [.ml] top comment for the
    concrete [O_DIRECT]/[openat2]/zero-length-transfer pitfalls this implementation had to work
    around -- including why [O_DIRECT] (present in this task's original brief) was dropped in
    favor of [O_DSYNC] alone. *)

include Storage_intf.S

val create : sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> string -> t
(** [create ~sw ~fs dir_path] opens (creating if necessary) a WAL directory at [dir_path].
    [wal_highest_op_number] is recovered from whatever entry files already exist on disk at
    [dir_path], so reopening the same directory after a process restart picks up exactly where
    the previous process left off.

    [File_storage]-specific limitation, not part of the abstract {!Storage_intf.S} contract:
    [wal_append] raises [Invalid_argument] for any entry larger than one fixed-buffer chunk
    (currently 4096 bytes), since this primitive writes each entry in a single fixed-buffer
    [io_uring] write. *)
