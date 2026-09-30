;; Task 3 fixture: a minimal guest that imports the host's "log" function and,
;; on `handle`, logs a fixed string once and returns an empty result.
;;
;; ABI (this task's own provisional convention -- see lib/module/loader.ml):
;;   - guest imports host functions from module namespace "host" by name
;;     ("log", "read_materialized", "propose_write" are the only recognized
;;     names); a guest may import any subset of them.
;;   - guest must export its linear memory as "memory".
;;   - the entrypoint (`handle` here) takes (arg_ptr: i32, arg_len: i32) and
;;     returns (result_ptr: i32, result_len: i32); the host writes the
;;     `invoke`-caller's `arg` bytes into guest memory at a fixed scratch
;;     offset (0x2000) before calling.
(module
  (import "host" "log" (func $log (param i32 i32)))

  (memory (export "memory") 1 4)

  ;; "hello", used as the fixed string logged by `handle`.
  (data (i32.const 0) "hello")

  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (call $log (i32.const 0) (i32.const 5))
    (i32.const 0)
    (i32.const 0))
)
