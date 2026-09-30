;; Task 3 fixture (code-review Finding 1 fix): a guest that declares a memory maximum far
;; beyond the loader's own enforced cap (1024 pages / 64 MiB) -- 65536 pages is the wasm spec's
;; own absolute ceiling for a 32-bit memory, ~4 GiB. Never actually instantiated for real (the
;; loader must reject it before ever calling into wasmtime); "handle" is present only so this
;; would otherwise be a structurally valid, ABI-conformant module if the cap didn't exist.
(module
  (memory (export "memory") 1 65536)
  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (i32.const 0)
    (i32.const 0))
)
