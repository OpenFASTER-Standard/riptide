;; Task 6 (task-master), subtask 6.4 (task-3-brief.md of the layer2-ledger-module plan): the real
;; WASM guest for the double-entry ledger module. Follows counter.wat/propose_write.wat/
;; read_materialized.wat's exact ABI convention (imports from "host", memory exported as "memory",
;; `handle(arg_ptr, arg_len) -> (result_ptr, result_len)`) and, per the design spec's Decision 3
;; (docs/superpowers/specs/2026-10-01-layer2-ledger-module-design.md), ignores `arg` entirely and
;; instead re-reads its own subscribed key via host.read_materialized -- the same precedent
;; counter.wat already established, for the same reason (parsing the reactor's real canonical
;; Value.value encoding by hand in WAT is real, separate complexity no fixture here takes on).
;;
;; ── On the 64-bit-arithmetic question the brief explicitly raises ──────────────────────────────
;; NOT truncated to 32 bits. loader.ml links the REAL wasmtime (v49.0.1 C API, see loader.ml's own
;; top comment) and compiles this file through its genuine `wat_to_wasm`/wat2wasm -- i.e. this is
;; the real WebAssembly text format, with full native `i64` load/store/compare/div/rem support, not
;; a hand-rolled minimal parser. Every amount/balance comparison below is a real `i64.gt_s` over the
;; full 64-bit value read straight out of the 8-byte LE fields Wire.ml writes -- no field is ever
;; reduced to its low 32 bits. SIGNED (`_s`), not unsigned, and that is a correctness fix rather
;; than a style preference (final whole-branch review, finding I1): Wire.encode_balance/
;; decode_balance round-trip NEGATIVE balances faithfully and are tested doing so, so an overdrawn
;; account's balance really can arrive here as a negative i64. Read with `i64.gt_u` -- as this
;; file originally did -- such a balance compares as roughly 1.8e19, i.e. richer than any
;; conceivable transfer, and the sufficient-funds check silently approves every further withdrawal
;; from an account that is already in the red. The account-id formatting routine below stays
;; UNSIGNED, which is sound for the opposite reason: Authorize.authorize structurally refuses any
;; leg or request naming a negative account, so an id reaching this guest is always non-negative
;; (finding I2), and for those the unsigned and signed renderings are identical. The one place a genuinely new, nontrivial routine was needed is
;; `$u64_to_decimal` below (see its own comment) -- building the dynamic merge_key string
;; "ledger.account.<id>" this guest needs to look up its own counterparty's balance requires
;; converting a 64-bit account id to its decimal ASCII representation by hand, which has no
;; shortcut the way a fixed-width byte comparison does. It is written for the FULL 64-bit domain
;; (unsigned, up to 20 decimal digits), not scoped down to whatever this task's own tests happen to
;; exercise.
;;
;; ── Wire convention (this module's own, private agreement between these closures and the
;;    ~read/~propose closures in test/test_ledger_end_to_end.ml -- see Decision 3) ───────────────
;;   - read_materialized("ledger.requests") -> exactly 32 bytes: request_id ++ from_account ++
;;     to_account ++ amount, each an 8-byte LE i64, in that field order (Wire.encode_request).
;;   - read_materialized("ledger.account." ++ decimal(account)) -> exactly 8 bytes (the balance, an
;;     LE i64, Wire.encode_balance) or zero bytes (balance 0, Wire's/counter.wat's "no value yet"
;;     convention).
;;   - propose_write takes 33 bytes: a one-byte DECISION TAG (0 = declined, 1 = accepted)
;;     immediately followed by the SAME 32 bytes handle read for "ledger.requests"
;;     (Wire.encode_decision). The request bytes are forwarded verbatim from where
;;     read_materialized already left them; only the tag byte is written here.
;;
;; ── Why this guest calls propose_write on BOTH outcomes, including a decline ────────────────────
;; Final whole-branch review, finding C1 (a Critical). This guest originally returned early, with
;; no propose_write call at all, when it decided insufficient funds -- a "clean no-op", which read
;; as obviously correct and was not. A decision nothing records leaves no trace anywhere, and this
;; guest is re-dispatched whenever its triggering "ledger.requests" write is re-materialized, which
;; is routine rather than exotic (Batch_commit.propose re-materializes unconditionally on every
;; retry; the empty-writes drain idiom and materialize_up_to do too). On such a re-dispatch this
;; guest re-reads the CURRENT balance -- which may have grown since -- legitimately decides ACCEPT
;; where it previously declined, and a transfer no client ever re-requested moves real money.
;; Reporting the decline explicitly is what lets the host record it and make it final; see
;; Accumulator.handle_guest_decision for that half.
;;
;; ── Memory layout (all offsets fixed, chosen so no two buffers below ever overlap) ─────────────
;;   0..14    "ledger.requests"            (15 bytes, read_materialized's own fixed key)
;;   16..19   "disp"                       (4 bytes, the fixed host.log marker -- same technique
;;                                           counter.wat uses so Reactor.For_testing.log_call_count
;;                                           proves this guest's handle genuinely ran, on EVERY
;;                                           dispatch, including the insufficient-funds no-op path)
;;   32..46   "ledger.account."            (15 bytes, the fixed merge_key prefix every account key
;;                                           is built from -- matches Schema.account_merge_key's
;;                                           own "ledger.account.%Ld" format exactly)
;;   63       the 1-byte decision tag (0 = declined, 1 = accepted), written immediately before the
;;              request bytes below so that offset 63, length 33, is exactly the contiguous
;;              Wire.encode_decision payload propose_write expects -- no copying needed
;;   64..95   the 32-byte transfer_request read_materialized("ledger.requests") writes here:
;;              64..71 request_id, 72..79 from_account, 80..87 to_account, 88..95 amount
;;   128..162 the dynamically-built "ledger.account.<from_account>" key: prefix copied to
;;             128..142 (15 bytes), decimal digits of from_account written starting at 143 (up to
;;             20 bytes for a full-range u64, so 143..162)
;;   192..199 the 8-byte balance read_materialized("ledger.account.<from_account>") writes here
;;
;; Same ptr+len/memory-export ABI convention as every other fixture in this directory (see
;; loader.ml's top comment): host.log is (ptr, len) -> (); host.read_materialized is
;; (key_ptr, key_len, out_ptr) -> written_len (0 = no value yet); host.propose_write is
;; (ptr, len) -> status (0 = Ok, 1 = Err -- ignored here, `drop`ped, the same way counter.wat
;; ignores it: this guest has already done everything it is going to do by the time it calls this).
(module
  (import "host" "log" (func $log (param i32 i32)))
  (import "host" "read_materialized" (func $read_materialized (param i32 i32 i32) (result i32)))
  (import "host" "propose_write" (func $propose_write (param i32 i32) (result i32)))

  (memory (export "memory") 1 4)

  (data (i32.const 0) "ledger.requests")
  (data (i32.const 16) "disp")
  (data (i32.const 32) "ledger.account.")

  ;; $u64_to_decimal: writes the decimal ASCII representation of the full unsigned 64-bit value
  ;; $n at $out (no leading zeros; "0" for zero) and returns the number of bytes written. Standard
  ;; two-pass approach (no string-building primitive exists at the WAT level): pass 1 repeatedly
  ;; divides by 10 and writes each remainder digit left-to-right, which produces the digits in
  ;; REVERSED order (least-significant first); pass 2 reverses that span in place. Operates on the
  ;; genuine full i64 domain throughout (i64.rem_u/i64.div_u), not a 32-bit-reduced approximation --
  ;; this is the one place in this guest doing real multi-step arithmetic, called out in this file's
  ;; own top comment.
  (func $u64_to_decimal (param $n i64) (param $out i32) (result i32)
    (local $i i32)
    (local $tmp i64)
    (local $digit i64)
    (local $lo i32)
    (local $hi i32)
    (local $t i32)

    (if (i64.eqz (local.get $n))
      (then
        (i32.store8 (local.get $out) (i32.const 48))
        (return (i32.const 1))))

    (local.set $tmp (local.get $n))
    (local.set $i (i32.const 0))
    (block $extract_done
      (loop $extract_loop
        (br_if $extract_done (i64.eqz (local.get $tmp)))
        (local.set $digit (i64.rem_u (local.get $tmp) (i64.const 10)))
        (i32.store8
          (i32.add (local.get $out) (local.get $i))
          (i32.add (i32.wrap_i64 (local.get $digit)) (i32.const 48)))
        (local.set $tmp (i64.div_u (local.get $tmp) (i64.const 10)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $extract_loop)))

    (local.set $lo (i32.const 0))
    (local.set $hi (i32.sub (local.get $i) (i32.const 1)))
    (block $reverse_done
      (loop $reverse_loop
        (br_if $reverse_done (i32.ge_s (local.get $lo) (local.get $hi)))
        (local.set $t (i32.load8_u (i32.add (local.get $out) (local.get $lo))))
        (i32.store8
          (i32.add (local.get $out) (local.get $lo))
          (i32.load8_u (i32.add (local.get $out) (local.get $hi))))
        (i32.store8 (i32.add (local.get $out) (local.get $hi)) (local.get $t))
        (local.set $lo (i32.add (local.get $lo) (i32.const 1)))
        (local.set $hi (i32.sub (local.get $hi) (i32.const 1)))
        (br $reverse_loop)))

    (local.get $i))

  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (local $req_len i32)
    (local $from_account i64)
    (local $amount i64)
    (local $ci i32)
    (local $digit_len i32)
    (local $key_len i32)
    (local $bal_len i32)
    (local $balance i64)

    ;; Observable proof this dispatch genuinely ran its guest code, on every outcome (same
    ;; technique as counter.wat's own "tick" marker) -- logged unconditionally, before any decision
    ;; below, so even the insufficient-funds no-op path still increments
    ;; Reactor.For_testing.log_call_count.
    (call $log (i32.const 16) (i32.const 4))

    ;; Per Decision 3: `arg` is ignored entirely. Re-read the triggering request directly.
    (local.set $req_len (call $read_materialized (i32.const 0) (i32.const 15) (i32.const 64)))
    (if (i32.ne (local.get $req_len) (i32.const 32))
      (then
        ;; Defensive only -- Decision 3's own sequential-dispatch contract (materialize always
        ;; happens before this dispatch, never concurrently) means this should never actually be
        ;; reached by this module's own test driver. A silent no-op IS right here, and this is the
        ;; one path where it still is: with no readable request there is no request_id to report a
        ;; decision ABOUT, so there is nothing propose_write could usefully say. That is the
        ;; opposite of the insufficient-funds case below, which has a perfectly well-formed request
        ;; in hand and must therefore report its decline rather than stay silent (finding C1).
        (return (i32.const 0) (i32.const 0))))

    (local.set $from_account (i64.load (i32.const 72)))
    (local.set $amount (i64.load (i32.const 88)))

    ;; Build the dynamic key "ledger.account.<from_account>" at offset 128: copy the fixed
    ;; 15-byte prefix from offset 32, then append from_account's own decimal digits.
    (local.set $ci (i32.const 0))
    (block $copy_done
      (loop $copy_loop
        (br_if $copy_done (i32.ge_s (local.get $ci) (i32.const 15)))
        (i32.store8
          (i32.add (i32.const 128) (local.get $ci))
          (i32.load8_u (i32.add (i32.const 32) (local.get $ci))))
        (local.set $ci (i32.add (local.get $ci) (i32.const 1)))
        (br $copy_loop)))
    (local.set $digit_len (call $u64_to_decimal (local.get $from_account) (i32.const 143)))
    (local.set $key_len (i32.add (i32.const 15) (local.get $digit_len)))

    ;; Current balance: absent (bal_len = 0) means balance 0, matching counter.wat's own "no
    ;; value yet" convention and Wire's own documented contract for this key.
    (local.set $bal_len (call $read_materialized (i32.const 128) (local.get $key_len) (i32.const 192)))
    (if (i32.eqz (local.get $bal_len))
      (then (local.set $balance (i64.const 0)))
      (else (local.set $balance (i64.load (i32.const 192)))))

    ;; The business decision this module exists to make: sufficient funds, full 64-bit SIGNED
    ;; compare (see this file's own top comment on finding I1 for why `_s` and not `_u`).
    (if (i64.gt_s (local.get $amount) (local.get $balance))
      (then
        ;; Insufficient funds. Still reported, explicitly, via propose_write with the decision tag
        ;; set to 0 -- NOT a silent early return (finding C1; see this file's top comment). The
        ;; host records the decline and proposes nothing, which is what makes it final.
        (i32.store8 (i32.const 63) (i32.const 0)))
      (else
        ;; Sufficient funds: the same tag byte set to 1.
        (i32.store8 (i32.const 63) (i32.const 1))))

    ;; One call on BOTH paths: the tag byte at 63 followed by the SAME 32 request bytes already
    ;; resident at 64..95, i.e. exactly Wire.encode_decision's 33-byte layout. The host's own
    ;; ~propose closure decodes these directly into the decision plus the transfer_request it
    ;; builds both legs from.
    (drop (call $propose_write (i32.const 63) (i32.const 33)))
    (i32.const 0)
    (i32.const 0))
)
