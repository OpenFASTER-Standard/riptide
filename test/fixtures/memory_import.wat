;; Task 3 fixture (code-review Finding: memory-import bypasses the local-declaration-only
;; memory-limit check): a guest that IMPORTS its memory rather than declaring it locally.
;; This loader's own host ABI only ever supplies function imports (see loader.ml's
;; Wasm_binary.func_imports) -- a memory (or table/global) import must be rejected at load time
;; with a clear Failure, not fall through to wasmtime's own opaque arity-mismatch Trap.
(module
  (import "host" "memory" (memory 1))
  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (i32.const 0)
    (i32.const 0))
)
