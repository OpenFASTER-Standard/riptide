;; Task 3 fixture: a guest that calls the host's "read_materialized" import and returns
;; whatever bytes it got back (or zero bytes, for the "no value" case) as its own result --
;; proves the round trip (host closure -> guest, guest -> invoke's own caller) in both
;; directions, for both the Some and None cases.
;;
;; Selector convention (this fixture's own, not part of the general loader ABI): the caller's
;; `arg` byte 0 selects which key to look up -- 0 looks up "known" (5 bytes, at offset 0), any
;; other value looks up "missing" (7 bytes, at offset 16). Same ptr+len/memory-export ABI
;; convention as echo.wat/runaway.wat (see loader.ml's top comment).
(module
  (import "host" "read_materialized" (func $rm (param i32 i32 i32) (result i32)))

  (memory (export "memory") 1 4)

  (data (i32.const 0) "known")
  (data (i32.const 16) "missing")

  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (local $len i32)
    (if (i32.eqz (i32.load8_u (local.get $arg_ptr)))
      (then (local.set $len (call $rm (i32.const 0) (i32.const 5) (i32.const 64))))
      (else (local.set $len (call $rm (i32.const 16) (i32.const 7) (i32.const 64)))))
    (i32.const 64)
    (local.get $len))
)
