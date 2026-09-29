(* See this file's own [.mli] for the module-level contract and why this exists. *)

(* Real [flock(2)], bound in [riptide_flock_stubs.c]. Deliberately not [Unix.lockf] -- see the
   [.mli]'s own "Why flock(2)" section for the (process, inode) vs. open-file-description
   distinction that makes [fcntl] locks unusable for this module's purpose. *)
external flock_exclusive_nonblocking : Unix.file_descr -> bool
  = "riptide_flock_exclusive_nonblocking"

let lock_file_name = ".riptide-lock"

(* Review finding M4: this exact wording used to be independently duplicated in four places (here
   plus three test files) -- any future wording change meant a four-way manual edit, with nothing
   enforcing they stayed in sync. Exported (see the .mli) so every caller of [acquire] and every
   test asserting against its failure message goes through this one function instead. *)
let conflict_message ~caller ?owner dir_path =
  let owner_clause =
    match owner with
    | None -> ""
    | Some tag -> Printf.sprintf " -- currently claimed by owner tag %S" tag
  in
  Printf.sprintf
    "%s: %s is already locked by another open handle%s (a real flock(2), not this codebase's \
     separate logical owner-tag check -- see Riptide_storage.Dir_lock's own .mli)"
    caller dir_path owner_clause

let acquire ~sw ~caller ?describe_conflict dir_path =
  let path = Filename.concat dir_path lock_file_name in
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
  match flock_exclusive_nonblocking fd with
  | true -> Eio_unix.Fd.of_unix ~sw ~close_unix:true fd
  | false ->
    (* Not yet registered with [sw] (the lock attempt failed), so this is a plain, synchronous
       [Unix.close] -- there is nothing an Eio switch needs to know about an fd this function is
       about to fully own for zero more instructions. *)
    (try Unix.close fd with Unix.Unix_error _ -> ());
    let owner = match describe_conflict with Some f -> f () | None -> None in
    invalid_arg (conflict_message ~caller ?owner dir_path)
  | exception exn ->
    (* Review finding M2: [fd] was opened successfully above, but if [flock_exclusive_nonblocking]
       itself raises [Unix.Unix_error] (anything other than EWOULDBLOCK, which is the plain [false]
       case above, not an exception) -- e.g. a genuine I/O error -- [fd] was never registered with
       [sw] and would otherwise leak: nothing else in this function, or in the caller who never gets
       a value back, owns it. Close it explicitly before re-raising.

       Review finding 5 (re-review, round 2): capture the backtrace BEFORE running [Unix.close]
       below (any exception, even a caught-and-ignored one, can perturb what a plain [raise exn]
       would otherwise report) and re-raise with [Printexc.raise_with_backtrace] rather than a bare
       [raise exn] -- [raise exn] re-raises [exn] as a NEW raise, discarding the original
       backtrace, which is exactly the inconsistency this finding named: the other two
       exception-handling sites this same Task 11 review round added (the I1 fixes in
       [file_storage.ml]/[file_kv_store.ml]) already both preserve the original backtrace this
       way; this site, doing the identical "clean up an owned resource, then re-raise" thing, is
       now consistent with both. *)
    let bt = Printexc.get_raw_backtrace () in
    (try Unix.close fd with Unix.Unix_error _ -> ());
    Printexc.raise_with_backtrace exn bt
