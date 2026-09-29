(* See this file's own [.mli] for the module-level contract and why this exists. *)

(* Real [flock(2)], bound in [riptide_flock_stubs.c]. Deliberately not [Unix.lockf] -- see the
   [.mli]'s own "Why flock(2)" section for the (process, inode) vs. open-file-description
   distinction that makes [fcntl] locks unusable for this module's purpose. *)
external flock_exclusive_nonblocking : Unix.file_descr -> bool
  = "riptide_flock_exclusive_nonblocking"

let lock_file_name = ".riptide-lock"

let acquire ~sw ~caller dir_path =
  let path = Filename.concat dir_path lock_file_name in
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
  if flock_exclusive_nonblocking fd then Eio_unix.Fd.of_unix ~sw ~close_unix:true fd
  else begin
    (* Not yet registered with [sw] (the lock attempt failed), so this is a plain, synchronous
       [Unix.close] -- there is nothing an Eio switch needs to know about an fd this function is
       about to fully own for zero more instructions. *)
    (try Unix.close fd with Unix.Unix_error _ -> ());
    invalid_arg
      (Printf.sprintf
         "%s: %s is already locked by another open handle (a real flock(2), not this codebase's \
          separate logical owner-tag check -- see Riptide_storage.Dir_lock's own .mli)"
         caller dir_path)
  end
