;; Task 4 fixture: a guest whose "handle" entrypoint calls the host's "propose_write" import
;; unconditionally, without ever having been called via "init" first.
;;
;; Used by test_a_call_violating_the_declared_protocol_is_rejected_not_forwarded_to_the_guest to
;; prove that Loader.invoke rejects a call that violates its declared Protocol.t session-type FSM
;; BEFORE the guest is ever dispatched into -- not merely before its host-visible side effect
;; completes. If the protocol check were bypassed, wired in the wrong place, or run after the
;; guest already ran, this guest would call propose_write the instant "handle" is invoked -- the
;; test's own protocol only allows "init" (not "handle") as the first legal call from its
;; "init" state, so a correctly-wired Loader.invoke must never let this guest's own
;; $pw call happen at all.
;;
;; Same ptr+len/memory-export ABI convention as propose_write.wat (see loader.ml's top comment).
(module
  (import "host" "propose_write" (func $pw (param i32 i32) (result i32)))

  (memory (export "memory") 1 4)

  (func (export "handle") (param $arg_ptr i32) (param $arg_len i32) (result i32 i32)
    (local $status i32)
    (local.set $status (call $pw (local.get $arg_ptr) (local.get $arg_len)))
    (i32.store8 (i32.const 64) (local.get $status))
    (i32.const 64)
    (i32.const 1))
)
