;; Final-fix-wave fixture (review finding I7): a guest that performs a GENUINE out-of-bounds
;; linear-memory access -- the one half of Decision 5's own named isolation test list
;; ("a module that deliberately loops forever OR overruns its own memory is contained") that had no
;; real test: runaway.wat covers the infinite-loop half, and the memory-limit fixtures
;; (oversized_memory.wat/unbounded_memory.wat/memory_import.wat) all get rejected at INSTANTIATE
;; time, before any guest code runs at all. Nothing exercised a real, running guest trapping.
;;
;; It declares one page (64 KiB, max 4) and loads from offset 0x7ffffffc -- ~2 GiB out, so this is
;; unambiguously out of bounds at any legal memory size this loader's own cap
;; (Loader.memory_pages_cap = 1024 pages) could ever permit, not a borderline off-by-one that a
;; future cap change might quietly turn into a legal access.
;;
;; Expected outcome (test_module_loader.ml): wasmtime traps inside the forked child, the child
;; reports the trap message back over the containment pipe as a clean 'E' failure, and
;; Loader.invoke returns Error -- not a host crash, and NOT the wall-clock "fuel exhausted" path,
;; which is a different containment mechanism entirely (the guest here terminates immediately).
;;
;; Same ptr+len/memory-export ABI convention as every other fixture here (see loader.ml's top
;; comment).
(module
  (memory (export "memory") 1 4)

  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (drop (i32.load (i32.const 0x7ffffffc)))
    ;; Never reached: the load above traps. Present only so the function is well-typed against the
    ;; (result i32 i32) this ABI requires of every entrypoint.
    (i32.const 0)
    (i32.const 0))
)
