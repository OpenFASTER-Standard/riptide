;; Task 3 fixture (code-review Finding 1 fix): a guest that declares a memory with NO maximum
;; at all (unbounded growth) -- the loader treats this as itself a violation, not merely an
;; unusually large but bounded one, since an unbounded memory enforces nothing against a guest
;; that grows it without limit at runtime.
(module
  (memory (export "memory") 1)
  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (i32.const 0)
    (i32.const 0))
)
