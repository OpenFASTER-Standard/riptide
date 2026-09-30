;; Fix-wave round 2 fixture: a guest that makes ONE fire-and-forget host.log call and then spins
;; forever. Exists to pin the containment property that the first cut of finding I2's fix broke.
;;
;; Why this specific shape. `host.log` is the one host import with no return value and no response
;; frame: the guest's `call $log` writes its message to the containment pipe and returns
;; IMMEDIATELY (see make_host_extern's "log" case in lib/module/loader.ml -- nothing reads a reply).
;; So unlike `read_materialized`/`propose_write`, the guest keeps executing, at full speed, while
;; the parent is still busy inside the caller-supplied log closure. Crediting that parent-side time
;; back to the guest's wall-clock fuel deadline -- which round 1 of the I2 fix wrongly did for all
;; three arms -- therefore hands a guest free execution time it IS using: one slow log call bought
;; this fixture's infinite loop an extra whole fuel budget of spinning, and a guest looping
;; log-then-compute could extend its own deadline without limit. That is a containment escape in the
;; exact mechanism whose only job is bounding untrusted guest execution.
;;
;; Expected outcome (test_module_loader.ml): the guest is SIGKILLed and reported as fuel-exhausted
;; on schedule -- specifically, NOT one budget later than the slow log closure itself takes. The
;; test's oracle is elapsed wall-clock time, since both the correct and the broken behavior return
;; Error; only WHEN differs.
;;
;; Same ptr+len/memory-export ABI convention as every other fixture here (see loader.ml's top
;; comment); the loop shape is runaway.wat's.
(module
  (import "host" "log" (func $log (param i32 i32)))

  (memory (export "memory") 1 4)

  (data (i32.const 0) "spin")

  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (call $log (i32.const 0) (i32.const 4))
    (loop $forever
      br $forever)
    ;; Never reached.
    (i32.const 0)
    (i32.const 0))
)
