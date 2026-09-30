;; Task 3 fixture: a guest whose `handle` loops forever with no host calls and
;; no recursion (so neither a stack-depth bound nor a real fuel counter -- had
;; one been available -- would even be exercised the same way; this is the
;; simplest module shape that proves the loader's containment mechanism, not
;; wasmtime's own fuel metering, which the installed wasmtime 0.0.3 OCaml
;; binding does not expose at all -- see lib/module/loader.ml's top comment).
;;
;; Same ABI convention as echo.wat: imports "host"."log" (unused here, just
;; kept for a uniform import list across fixtures), exports "memory" and
;; "handle".
(module
  (import "host" "log" (func $log (param i32 i32)))

  (memory (export "memory") 1 4)

  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (loop $forever
      br $forever)
    (i32.const 0)
    (i32.const 0))
)
