/* Real flock(2) binding backing Riptide_storage.Dir_lock -- see dir_lock.mli for why this needs
   to be flock(2) specifically, not OCaml's own Unix.lockf (POSIX fcntl locks, which are scoped to
   a (process, inode) pair rather than an open file description and so would not conflict against
   a second open() from the SAME process -- exactly the case Task 11's own single-process tests
   need to observe a conflict for). Neither the OCaml stdlib Unix module nor any opam package
   already installed in this switch exposes flock(2) directly, so this is a small, direct binding
   rather than a dependency addition. */

#include <sys/file.h>
#include <errno.h>

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>

/* [riptide_flock_exclusive_nonblocking fd] takes a real, non-blocking, exclusive flock(2) lock on
   [fd] (a Unix.file_descr, represented at runtime as a plain int on this platform -- the same
   convention the OCaml stdlib's own otherlibs/unix stubs use throughout).

   Returns [true] if the lock was acquired. Returns [false] only for EWOULDBLOCK -- i.e. another
   open file description already holds this lock -- the one outcome the OCaml side
   (Dir_lock.acquire) treats as an ordinary, expected refusal rather than a raised exception. Any
   OTHER errno (a genuine I/O error, an unsupported filesystem, etc.) raises a real
   [Unix.Unix_error] via [uerror], matching how every other syscall this codebase wraps
   (Unix.openfile, Unix.fsync, ...) surfaces a genuine failure -- silently swallowing anything
   other than EWOULDBLOCK here would hide a real problem behind what looks like an ordinary lock
   refusal.

   [LOCK_NB] means the underlying syscall itself never blocks (it returns EWOULDBLOCK immediately
   rather than waiting), so unlike a genuinely blocking syscall this has no need to release the
   OCaml runtime lock around the call -- there is nothing else it would usefully let another
   thread/domain do while it (very briefly) runs. */
CAMLprim value riptide_flock_exclusive_nonblocking(value v_fd) {
  CAMLparam1(v_fd);
  int fd = Int_val(v_fd);
  int ret = flock(fd, LOCK_EX | LOCK_NB);

  if (ret == 0) CAMLreturn(Val_true);
  if (errno == EWOULDBLOCK) CAMLreturn(Val_false);
  uerror("flock", Nothing);
  CAMLreturn(Val_false); /* unreachable: uerror always raises */
}
