(** The host/guest byte wire for this module, and nothing else: a fixed-width, little-endian
    encoding shared only between {!Accumulator}'s own host closures and
    [test/fixtures/ledger.wat]. See
    docs/superpowers/specs/2026-10-01-layer2-ledger-module-design.md, Decision 3.

    {b This is this module's own PRIVATE agreement, not part of the general Layer 2 loader ABI} --
    exactly as [test/fixtures/counter.wat] and its own test already established a private
    raw-little-endian-i32 convention for ["count"]. The loader ABI itself only ever deals in
    opaque [(ptr, len)] byte ranges; what those bytes mean is entirely up to each module and the
    host closures wired to it. Changing anything here therefore requires changing [ledger.wat] in
    the same commit, and nothing outside this library and that fixture.

    {b Signedness, stated because getting it wrong is a real money bug and did happen} (final
    whole-branch review, finding I1): every field below is a SIGNED [int64], written and read via
    [Bytes.set_int64_le]/[Bytes.get_int64_le], and {!encode_balance}/{!decode_balance} round-trip
    NEGATIVE balances faithfully -- an overdrawn account is representable and this encoding
    preserves it. A guest comparing these bytes must therefore use WASM's SIGNED comparison
    operators ([i64.gt_s], [i64.le_s], ...). [ledger.wat]'s sufficient-funds check originally used
    [i64.gt_u], which read a negative balance back as roughly 1.8e19 and so approved every
    subsequent transfer out of an already-overdrawn account.

    No field is length-prefixed and no encoding here is self-delimiting: every message is a fixed
    number of bytes, so every [decode_*] function below rejects a wrong-length input outright
    rather than attempting a partial parse. *)

val request_bytes : int
(** [32] -- the exact length {!encode_request} produces and {!decode_request} accepts. *)

val decision_bytes : int
(** [33] -- the exact length {!encode_decision} produces and {!decode_decision} accepts: one
    decision tag byte followed by a full {!request_bytes}-byte request encoding. *)

val encode_request : Schema.transfer_request -> bytes
(** [encode_request r] is exactly {!request_bytes} bytes: [request_id ++ from_account ++
    to_account ++ amount], each an 8-byte little-endian signed [int64], in that field order. This
    is what the host's own [read_materialized] closure returns for
    {!Schema.requests_merge_key} -- i.e. how the guest learns what was asked for. *)

val decode_request : bytes -> Schema.transfer_request option
(** [decode_request b] is [None] -- never an exception -- unless [b] is exactly
    {!request_bytes} long. Any 32-byte input decodes successfully: every bit pattern is a valid
    pair of signed [int64]s, so there is no such thing as "32 bytes of garbage" at this layer.
    Judging whether the resulting request makes sense is {!Authorize.authorize}'s job, not
    this function's. *)

val encode_decision : accepted:bool -> Schema.transfer_request -> bytes
(** [encode_decision ~accepted r] is exactly {!decision_bytes} bytes: a single tag byte
    ([1] when [accepted], [0] when declined) followed by [encode_request r].

    {b This is what the guest hands back through [propose_write], on BOTH outcomes} -- an accepted
    transfer and a declined one alike (final whole-branch review, finding C1). A guest that simply
    returned without calling [propose_write] when it declined would leave its own decision with no
    durable trace anywhere, so any later re-materialization of the same already-committed request
    would re-dispatch it against a since-changed balance and could legitimately decide the other
    way -- see {!Accumulator.handle_guest_decision} for the host side of how a first decision is
    made final. The tag is first, not last, so a reader can branch on it before touching anything
    else. *)

val decode_decision : bytes -> (bool * Schema.transfer_request) option
(** [decode_decision b] is [Some (accepted, r)] when [b] is exactly {!decision_bytes} long and its
    first byte is [0] or [1]; [None] -- never an exception -- otherwise. {b Any other tag byte is
    rejected rather than coerced}: "not zero, so accepted" would silently turn a corrupt or
    truncated-then-padded payload into an approval to move money. *)

val decision_to_value : accepted:bool -> Schema.transfer_request -> Riptide.Value.value
(** [decision_to_value ~accepted r] is exactly {!encode_decision}[ ~accepted r]'s own
    {!decision_bytes} bytes, carried verbatim inside a [Value.Scalar (Value.Bytes _)] -- the payload
    of the DURABLE DECISION WRITE {!Legs.decision_write} builds and
    {!Accumulator.handle_guest_decision} commits (Task 7, the Layer 0/Layer 2 boundary revision).

    {b Why a decision is committed to the replicated log at all}, since the two legs of an accepted
    transfer already are: a DECLINE has no legs. Before this write shape existed, a declined request
    left no durable trace anywhere -- only an in-memory table in {!Accumulator} -- so a restart
    plus any catch-up materialization could re-dispatch the guest against a since-changed balance,
    get an ACCEPT, and move money no client ever asked twice for (final whole-branch review, finding
    C1, whose first fix was that volatile table). Committing the decision makes "has this request
    already been decided, and how?" a question the replicated log answers, which is what let that
    table be deleted outright rather than persisted in parallel.

    {b Why it carries the guest's own bytes rather than a Record of the same four fields}: so this
    module has exactly ONE decision wire format, with exactly one tag-byte validation
    ({!decode_decision}, the function the authorize fuzz test hammers), and so a committed decision
    is bit-identical to what the guest actually produced rather than a re-serialization of it. *)

val decision_of_value : Riptide.Value.value -> (bool * Schema.transfer_request) option
(** [decision_of_value v] is {!decode_decision} of the bytes [v] carries, or [None] -- never an
    exception -- if [v] is not a [Value.Scalar (Value.Bytes _)] at all. Total, and deliberately
    usable as a test for "is this write a decision record?": every OTHER payload that can appear in a
    batch this module commits is a [Value.Record], so no payload can be read as both. Exhaustively,
    those are:
    - a {!Schema.transfer_request} ({!Schema.transfer_request_to_value});
    - a {!Schema.transfer_leg} ({!Schema.transfer_leg_to_value});
    - the synthetic ["riptide.module.authz"] authorization-decision write that
      {!Riptide_batch_commit.Batch_commit.propose} APPENDS to every batch it proposes once every write
      has been [Allow]ed ([batch_commit.mli]'s own "Authorization" section) -- a [Value.Record] of
      idempotency_key + decision. This module neither authors nor can see it at propose time, but
      every caller walking a COMMITTED batch's writes scans past it, so leaving it out of this
      enumeration made the list read as complete while omitting the one shape a committed ledger batch
      carries that this module did not write (final whole-branch review, Minor -- the same omission was
      already closed in [accumulator.ml]'s own copy of this enumeration and left unfixed here). *)

val encode_balance : int64 -> bytes
(** [encode_balance bal] is exactly 8 bytes, [bal] as a little-endian signed [int64]. This is what
    the host's own [read_materialized] closure returns for an {!Schema.account_merge_key}. A
    zero-length read, not a zero-valued one, is the "no value yet" convention for an account that
    has never been written to (matching [counter.wat]'s own precedent). *)

val decode_balance : bytes -> int64 option
(** [decode_balance b] is [None] -- never an exception -- unless [b] is exactly 8 bytes long. *)
