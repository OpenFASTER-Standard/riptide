;; Final-fix-wave fixture (review finding I7): the other half of Decision 5's own named isolation
;; test list -- "doesn't touch another module's or the core's memory" -- which was asserted nowhere,
;; despite being one of the two properties the whole SFI baseline exists to provide. Trivially true
;; given each invocation runs in its own forked process (separate address space) AND each
;; instantiate builds a fresh wasmtime instance with its own linear memory, but "trivially true"
;; and "observed to be true" are different things, and this repo's own CLAUDE.md ("no spec without
;; running code") treats the difference as load-bearing.
;;
;; Selector convention (this fixture's OWN, like read_materialized.wat's own selector byte -- not
;; part of the general loader ABI): the caller's `arg` byte 0 chooses a role.
;;   0       -> WRITER: store a fixed 4-byte sentinel at offset 256, then return those 4 bytes.
;;   nonzero -> READER: return the 4 bytes currently at offset 256, having written nothing at all.
;; Offset 256 is comfortably clear of Loader's own arg scratch offset (0x2000) so the host's own
;; marshaling can never be what a reader observes there.
;;
;; A reader that observes the sentinel would mean two separately-instantiated guests (or two
;; separate invocations) genuinely shared linear memory; a reader observing four zero bytes is WASM
;; memory's own zero-initialization, i.e. real isolation. Same ptr+len/memory-export ABI convention
;; as every other fixture here (see loader.ml's top comment). Imports nothing: the observable
;; result travels back through `invoke`'s own return value, so no host call is needed to see it.
(module
  (memory (export "memory") 1 4)

  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (if (i32.eqz (i32.load8_u (local.get $arg_ptr)))
      (then (i32.store (i32.const 256) (i32.const 0x5eed1234))))
    (i32.const 256)
    (i32.const 4))
)
