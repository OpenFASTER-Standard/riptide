# Implementation plan: VSR wire encoding and replica log primitives

First of several plans implementing the remainder of task-master subtask 3.2 ("the REAL
concurrency model for the actual VSR-derived protocol still needs to be designed and built" —
the proof-of-concept half is already merged). This plan builds the prerequisite data structures a
real replica implementation needs; it does not implement any protocol logic (no `ReceivePrepareMsg`,
no view-change actions) — that's a following plan, once these building blocks exist and are
tested in isolation.

## Research grounding (verified directly against this repo, not assumed)

- **`Value.canonical_encode` is one-directional.** Grepped the whole repo: no decoder exists
  anywhere (`decode`/`of_string`/`parse`/`canonical_decode` all return zero hits outside this
  plan). `lib/transport/transport_intf.ml`'s `send`/`receive` deal in raw `string` bytes — a real
  replica needs to turn received bytes back into structured data, which nothing today supports.
- **No VSR message wire format exists.** `spec/tla/VSR.tla`'s five message types (`Prepare`,
  `PrepareOk`, `StartViewChange`, `DoViewChange`, `StartView`) are TLA+ records with fields like
  `{type, view, n, v, k, dest}` — nothing in `lib/` encodes an arbitrary record like this today.
- **`lib/log.ml`'s existing `Log` module cannot represent `rep_log[r]` directly.** `Log.append`
  always extends at the log's own internally-tracked tail (no caller-specified position, no way to
  reject an out-of-order append); there is no indexed read (`rep_log[r][op_number]`, needed by
  `NoLogDivergence`/`PrimaryExecuteOp`/`ReceiveSV`); there is no wholesale-replace operation
  (`ReceiveSV`/`SendSV` overwrite a replica's entire log with a winning DVC's log on view-change
  completion — `Log` has no truncate/replace, only ever-growing append). `Log`'s hash-chaining and
  `Envelope` wrapping are also the wrong shape: VSR's `rep_log[r]` is `Seq(Values)` — a plain
  sequence of values, no `actor`/`causation`/`correlation` envelope metadata attached at this
  layer (that's a Layer 0 concept `Log` correctly owns; VSR's log is a lower-level replication
  primitive that doesn't need it).
- **`Value.value` is a structurally adequate candidate for VSR's abstract `Values` domain** — the
  TLA+ spec only ever compares elements with `=`, appends them to a sequence, and uses them as set
  elements; `Value.value` (closed algebraic type, equal after `Record`/`Map` field-order
  normalization, already has `content_hash` for structural identity) satisfies this with no new
  type required.

## Architecture

**A new library, `lib/vsr/`, houses everything specific to the VSR protocol implementation** —
this plan's two modules, and later plans' protocol logic. Nothing in `lib/vsr/` modifies
`lib/value.ml`, `lib/log.ml`, or `lib/transport/` (all three already have their own tested
consumers); this plan only ADDS `Value.canonical_decode` to the existing `Value` module (see Task
1 — this one addition is the exception, since it belongs on `Value` itself, not a wrapper).

- **Task 1**: `Value.canonical_decode`, the exact inverse of `canonical_encode`, added to the
  existing `lib/value.ml`/`.mli`.
- **Task 2**: `lib/vsr/message.ml` — VSR's five message types, each represented as a
  `Value.value` (via `Value.Sum` tagging, reusing `Value`'s own already-tested encoding rather
  than hand-rolling a second one) with typed OCaml constructor/accessor functions, built on
  `canonical_encode`/`canonical_decode`.
- **Task 3**: `lib/vsr/replica_log.ml` — a `Value.value Seq`-shaped log with the three operations
  `rep_log[r]` actually needs that `Log` doesn't provide: strict-op-number-ordered append,
  indexed read, and wholesale replace.

## Global Constraints

- `lib/log.ml`/`.mli`, `lib/transport/`, and `Value`'s existing `canonical_encode`/`content_hash`
  are **not modified** except for Task 1's one addition (`canonical_decode`) to `value.ml`/`.mli`.
- Every new encode/decode path must be defensive against adversarial/corrupt input (this data
  arrives over `Transport.S`, whose own contract promises no integrity guarantee — see
  `transport_intf.ml`) — never crash the process on malformed bytes; raise a well-typed exception,
  matching the discipline already established in `lib/transport/tcp.ml`'s `read_frame` bounds
  checking.
- `Value.canonical_decode` decodes a COMPLETE, EXACT byte string (matching how `Transport.S`
  already delivers whole-message boundaries via length-prefixed framing upstream) — it is not a
  streaming/incremental decoder, and it must reject (raise) if any trailing bytes remain after a
  complete value is decoded, not silently ignore them.
- Round-trip correctness (`decode (encode v) = v`, accounting for `Record`/`Map` field-order
  normalization — see Task 1's own note on this) must be proven by property tests (QCheck2,
  matching `test/test_value.ml`'s existing style and generator), not just example-based tests —
  this is exactly the kind of claim a hand-picked example set can miss a case on.

## Task 1: `Value.canonical_decode`

**Files:**
- Modify: `lib/value.ml`, `lib/value.mli`
- Modify: `test/test_value.ml`

**Steps:**

1. Read `lib/value.ml`'s `encode_into` (the full encoder, lines 40-105) closely — `canonical_decode`
   must be its exact structural inverse, tag byte for tag byte, length-prefix for length-prefix.
   Key details to get right:
   - Every constructor's tag byte (`tag_scalar_bool = '\x00'` through `tag_map = '\x08'`) — decode
     dispatches on this first byte.
   - `buf_add_len_prefixed`'s 8-byte big-endian length prefix — decode must read exactly 8 bytes,
     reconstruct the length, and validate it against the REMAINING buffer length before reading
     that many bytes (a corrupt/adversarial length claiming more bytes than actually remain must
     raise, not read out of bounds or loop forever — mirror `lib/transport/tcp.ml`'s
     `Frame_too_large`-style bounds-checking discipline, though you don't need the same named
     exception, your own is fine).
   - `Record`/`Sequence`/`Map`'s 8-byte big-endian element/entry COUNT prefix, distinct from the
     per-string length prefix — same bounds-checking discipline applies (a corrupt count claiming
     more entries than the remaining bytes could possibly contain must raise promptly, not attempt
     to decode astronomically many entries from a short input).
   - `Map`'s stored representation: `encode_into` encodes each entry's KEY by first running
     `encode_into` on it (producing raw encoded bytes), storing THAT as the length-prefixed
     "key string," then separately encoding the value. Decode must therefore, for `Map`, read a
     length-prefixed byte blob for the key and recursively decode THAT blob (not the outer stream
     directly) back into a `value`, then decode the value normally from the outer stream. Get this
     asymmetry right — it's the easiest place to get `canonical_decode` subtly wrong.
   - `Sum`'s shape: tag byte, then a length-prefixed STRING (the sum's own string tag, e.g.
     `"Envelope"` per `lib/envelope.ml`'s existing domain-separation use), then a recursively
     encoded value.
2. Implement `canonical_decode : string -> value`, decoding from position 0 and raising
   `Invalid_argument` (with a descriptive message — this project's established convention, see
   `Value.hash_to_hex`'s existing `Invalid_argument` use) if: the input is empty, an unknown tag
   byte is encountered, any length/count prefix would read past the end of the input, or bytes
   remain in the input after a complete value has been decoded (trailing-bytes check — a genuine
   decode of a well-formed prefix followed by garbage must be rejected as a whole, not silently
   accepted as "the first well-formed value found").
3. Add `val canonical_decode : string -> value` to `value.mli`, documented to the same standard as
   `canonical_encode`'s own doc comment (round-trip relationship, exception behavior, and the
   `Record`/`Map` field-order-normalization caveat: decoding a value re-encodes into the SAME
   canonical field order `canonical_encode` would have chosen, which is not necessarily the field
   order the ORIGINAL un-encoded value was constructed with if that value's fields were out of
   sorted order to begin with — a round-trip test must account for this, see Step 4).
4. Add tests to `test/test_value.ml`:
   - Example-based: decode a hand-constructed encoding of each of the 9 tag-byte shapes
     (`Bool`/`Int`/`Float`/`String`/`Bytes`/`Record`/`Sum`/`Sequence`/`Map`), confirming the
     decoded value matches what was encoded.
   - Malformed-input tests: truncated input (cut off mid-length-prefix, mid-count-prefix,
     mid-payload), a claimed length/count that exceeds the remaining bytes, an unknown tag byte,
     trailing garbage after a complete value — confirm each raises `Invalid_argument` rather than
     crashing or hanging.
   - **Round-trip property test (QCheck2)**, reusing `test_value.ml`'s existing arbitrary-`value`
     generator: for any generated `v`, `canonical_decode (canonical_encode v)` is *value-equal* to
     `v` (define value-equality for this test as "encodes to the same bytes," i.e.
     `canonical_encode (canonical_decode (canonical_encode v)) = canonical_encode v` — this
     sidesteps the field-order-normalization caveat cleanly and is a stronger, more useful property
     than trying to define a custom structural equality that special-cases field order).
5. Run `dune test` and confirm everything passes, including all pre-existing tests (this task adds
   to `value.ml`/`.mli`/`test_value.ml` only — nothing else should be affected).
6. Commit.

## Task 2: VSR message wire format

**Files:**
- Create: `lib/vsr/dune`, `lib/vsr/message.ml`, `lib/vsr/message.mli`
- Create: `test/test_vsr_message.ml`
- Modify: `test/dune`, `test/test_riptide.ml`

**Steps:**

1. Define an OCaml type per VSR message, transcribing `spec/tla/VSR.tla`'s exact field lists
   (verified against the spec file directly, not from memory — quoted here for convenience, but
   re-check against the actual file before implementing, in case it has changed since this plan
   was written):
   ```ocaml
   type t =
     | Prepare of { view : int; n : int; v : Value.value; k : int }
     | Prepare_ok of { view : int; n : int; i : int }
     | Start_view_change of { v : int; i : int }
     | Do_view_change of {
         v : int; log : Value.value list; last_normal_view : int; n : int; k : int; i : int;
       }
     | Start_view of { v : int; log : Value.value list; n : int; k : int }
   ```
   Omit `dest` from every constructor — that field exists in the TLA+ spec only because TLA+'s
   message-bag model needs an explicit destination on the message itself; in the real
   implementation, `Transport.S.send`'s own `~to_:int` argument already carries the destination,
   so encoding it a second time INSIDE the message body would be redundant. Document this
   omission explicitly in `message.mli` so a future reader checking against the TLA+ spec isn't
   confused by the mismatch.
2. Implement `encode : t -> string` and `decode : string -> t`, built on Task 1's
   `Value.canonical_decode`/`Value.canonical_encode`: convert each `t` constructor to/from a
   `Value.Sum (tag_string, Value.Record [...])` shape (one string tag per constructor, e.g.
   `"Prepare"`, `"PrepareOk"`, etc. — exact tag strings are your choice, but keep them stable and
   documented since they're now part of this module's own wire format), then reuse
   `Value.canonical_encode`/`canonical_decode` for the actual byte-level work rather than
   hand-rolling a second independent encoder. `decode` must raise a clear, well-typed exception
   (your choice of exception type, documented in `message.mli`) on: bytes that don't decode as a
   `Value.value` at all (propagate or wrap `Value.canonical_decode`'s own `Invalid_argument`), a
   `Sum` tag string that doesn't match any of the five known message tags, or a `Record` missing
   an expected field or with a field of the wrong shape (e.g. `view` present but not an `Int`
   scalar).
3. Add tests to `test/test_vsr_message.ml`: one round-trip test per message constructor (`encode`
   then `decode` recovers the original), and malformed-input tests (unknown Sum tag, missing
   field, wrong field type) confirming `decode` raises rather than crashing. A round-trip property
   test (QCheck2) generating random instances of each constructor is worth the effort here too,
   matching Task 1's own discipline, but hand-written examples covering every constructor at least
   once are the minimum bar.
4. `dune build`/`dune test`, confirm clean.
5. Commit.

## Task 3: `Replica_log` — the log shape `rep_log[r]` actually needs

**Files:**
- Create: `lib/vsr/replica_log.ml`, `lib/vsr/replica_log.mli`
- Create: `test/test_vsr_replica_log.ml`
- Modify: `test/dune`, `test/test_riptide.ml`

**Steps:**

1. Design and implement a module matching exactly the three operations `spec/tla/VSR.tla`'s
   actions perform on `rep_log[r]` (re-read the spec's own `ReceivePrepareMsg`, `PrimaryExecuteOp`,
   `SendSV`/`ReceiveSV` actions directly before implementing, to confirm you're matching real
   usage, not a guessed shape):
   - **Strict-op-number-ordered append**: a new entry may only be appended at exactly
     `current_length + 1` (matching `ReceivePrepareMsg`'s guard `rep_op_number[r] + 1 = m.n`) —
     reject (raise, your choice of exception) an attempt to append anywhere else, rather than
     silently ignoring or reordering.
   - **Indexed read**: `get : t -> op_number:int -> Value.value option` (1-indexed, matching
     `rep_log[r][op_number]`'s TLA+ indexing convention exactly — op-number 1 is the first entry).
   - **Wholesale replace**: `replace_with : t -> Value.value list -> unit` (or a functional
     `replace_with : Value.value list -> t`, your choice of mutable-vs-functional style — check
     which convention `lib/log.ml`'s own `log` type uses and stay consistent with this codebase's
     existing pattern rather than introducing a second style) — used by `ReceiveSV`/`SendSV` to
     adopt a winning DVC's log wholesale, discarding whatever was there before.
   - `length : t -> int` — must always equal the number of entries (this is
     `LogLengthMatchesOpNumber`'s own invariant from `VSR.tla`, and this module's job is to make
     that invariant hold by construction, not by a caller's separate bookkeeping discipline).
2. Do NOT add hash-chaining, `Envelope` wrapping, or any Layer-0-specific metadata — this is
   VSR's own replication-level log, a plain sequence of `Value.value`, deliberately simpler than
   `lib/log.ml`'s `Log` (which is Layer 0's own, different, already-shipped concept). If you find
   yourself wanting to reuse `Log`'s internals, stop — the Research Grounding section above already
   established why `Log`'s shape doesn't fit; a fresh, simple module is the right call here, not a
   wrapper around `Log`.
3. Tests in `test/test_vsr_replica_log.ml`: append-in-order succeeds and is readable via `get`;
   append-out-of-order (too high, too low, a gap) is rejected; `get` on an out-of-range
   `op_number` (0, negative, beyond the current length) returns `None` rather than raising (your
   choice, but document and test whichever behavior you pick clearly); `replace_with` discards
   prior entries and `length`/`get` reflect the new content immediately afterward; `length` stays
   correct through a sequence of appends and a replace.
4. `dune build`/`dune test`, confirm clean, including all pre-existing suites.
5. Commit.

## Self-Review Notes

- **Spec coverage**: this plan implements none of `spec/tla/VSR.tla`'s own actions — it only
  builds the data structures a following plan's protocol-logic implementation will need
  (message wire format, replica log). This is a deliberate scope boundary, not an oversight —
  keeping this plan small and independently testable, per this project's own "small, aligned
  governance" principle, rather than bundling data-structure work into the much larger, much
  higher-risk protocol-logic implementation plan.
- **Blast radius check**: only `value.ml`/`.mli` (one addition, `canonical_decode`) and a new
  `lib/vsr/` library are touched. `lib/log.ml`, `lib/transport/`, `lib/envelope.ml` are all
  untouched — verified against this plan's own file lists above.
- **Toolchain/prior-art grounding**: `encode_into`'s exact byte layout was read directly from
  `lib/value.ml` (quoted precisely in Task 1's own steps) before this plan was written, not
  assumed — the `Map` key-encoding asymmetry in particular is a real, easy-to-miss detail flagged
  explicitly so Task 1's implementer doesn't rediscover it the hard way.
- **What the NEXT plan (protocol logic) will need from this one, noted for continuity**: the real
  replica implementation will need per-replica state beyond just the log (view number, status,
  commit number, etc. — see `spec/tla/VSR.tla`'s full `VARIABLES` list) and the actual transcription
  of all 11 TLA+ actions into OCaml functions operating over `Transport.S` and this plan's
  `Message`/`Replica_log` modules. None of that is this plan's job.
