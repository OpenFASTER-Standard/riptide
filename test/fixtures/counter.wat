;; Task 7 fixture: counter.wat -- the "one real, demanding module" this end-to-end test
;; (test_module_end_to_end.ml) uses to pressure-test the whole Layer 0/Layer 2 boundary for real
;; (task-7-brief.md). Combines Task 3's own single-purpose read_materialized.wat and
;; propose_write.wat fixtures into one guest that does both in sequence, plus a host.log call
;; (like echo.wat) so a dispatch is externally observable: on `handle`, it (1) logs a fixed
;; marker, (2) reads its own subscribed key ("count") via host.read_materialized, (3) adds 1, and
;; (4) proposes the incremented value back via host.propose_write -- which, once committed,
;; re-materializes and re-triggers this same guest on its own output (bounded on the test's own
;; side, not this guest's -- see test_module_end_to_end.ml's own retrigger-count closures).
;;
;; Same ptr+len/memory-export ABI convention as every other fixture in this directory (see
;; loader.ml's top comment): host.log is (ptr, len) -> (); host.read_materialized is
;; (key_ptr, key_len, out_ptr) -> written_len (0 = no value yet); host.propose_write is
;; (ptr, len) -> status (0 = Ok, 1 = Err -- ignored here, `drop`ped, the same way this guest has
;; no way to react to it beyond what it already did, by this ABI's own design).
;;
;; Value convention (this fixture's OWN, not part of the general loader ABI, exactly like
;; read_materialized.wat's own "selector byte" convention is its own): the value materialized at
;; "count" is a single raw little-endian i32 -- the simplest shape a hand-written guest with no
;; allocator can parse and produce, agreed on only between this guest and
;; test_module_end_to_end.ml's own ~read/~propose closures (nothing else in this codebase
;; interprets a "count" merge_key's bytes this way).
(module
  (import "host" "log" (func $log (param i32 i32)))
  (import "host" "read_materialized" (func $read_materialized (param i32 i32 i32) (result i32)))
  (import "host" "propose_write" (func $propose_write (param i32 i32) (result i32)))

  (memory (export "memory") 1 4)

  ;; "count" -- the merge_key this guest always reads, regardless of `handle`'s own `arg` (the
  ;; reactor's own triggering materialized value, unused by this guest: it independently re-reads
  ;; its subscribed key every dispatch, per this task's own brief).
  (data (i32.const 0) "count")
  ;; "tick" -- the fixed marker this guest logs once per `handle` invocation, the observable proof
  ;; (via Reactor.For_testing.log_call_count) that a dispatch genuinely ran its guest code, the
  ;; same technique Task 6's own tests already use against echo.wat.
  (data (i32.const 32) "tick")

  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (local $len i32)
    (local $current i32)
    (call $log (i32.const 32) (i32.const 4))
    (local.set $len (call $read_materialized (i32.const 0) (i32.const 5) (i32.const 64)))
    (if (i32.eqz (local.get $len))
      (then (local.set $current (i32.const 0)))
      (else (local.set $current (i32.load (i32.const 64)))))
    (i32.store (i32.const 80) (i32.add (local.get $current) (i32.const 1)))
    (drop (call $propose_write (i32.const 80) (i32.const 4)))
    (i32.const 0)
    (i32.const 0))
)
