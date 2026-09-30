;; Task 3 fixture: a guest that forwards its own `arg` bytes straight to the host's
;; "propose_write" import and returns the single status byte it got back (0 = Ok, 1 = Err) --
;; proves the guest's payload bytes genuinely reach the host closure unmodified, and that the
;; host's Ok/Error outcome genuinely reaches back to the guest (and out through `invoke`'s own
;; result), in both directions.
;;
;; Same ptr+len/memory-export ABI convention as echo.wat/runaway.wat (see loader.ml's top
;; comment) -- `arg` itself is exactly the payload proposed, no separate encoding needed.
(module
  (import "host" "propose_write" (func $pw (param i32 i32) (result i32)))

  (memory (export "memory") 1 4)

  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (local $status i32)
    (local.set $status (call $pw (local.get $arg_ptr) (local.get $arg_len)))
    (i32.store8 (i32.const 64) (local.get $status))
    (i32.const 64)
    (i32.const 1))
)
