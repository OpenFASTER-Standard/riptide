(** Wire format for VSR's five protocol message types (`spec/tla/VSR.tla`), built on
    {!Riptide.Value.canonical_encode}/{!Riptide.Value.canonical_decode} rather than a
    second, hand-rolled encoder.

    {2 Field lists}

    Each constructor's field list is transcribed verbatim from the record literals passed
    to `Send`/`Broadcast` in `spec/tla/VSR.tla` (checked directly against that file, not
    from memory) — [Prepare] from [ReceiveClientRequest], [Prepare_ok] from
    [ReceivePrepareMsg], [Start_view_change] from [TimerSendSVC], [Do_view_change] from
    [SendDVC], [Start_view] from [SendSV] — {b with one deliberate exception as of
    audit-remediation Task 3}: [Prepare] and [Start_view] each gained a [source : int]
    field neither has in the TLA+ model, closing the audit's single highest-severity
    finding (no sender authentication at all on either message type). See each
    constructor's own doc comment below for why.

    {b [dest] is deliberately omitted from every constructor here.} It exists in the TLA+
    spec only because TLA+'s message-bag delivery model needs an explicit destination
    carried on the message value itself; in this implementation, the transport layer's own
    [send ~to_:int ...] argument (see `lib/transport/transport_intf.ml`'s [S.send]) already
    carries the destination, so encoding it a second time inside the message body would be
    redundant. A reader
    checking this module's field lists against the TLA+ spec's record literals should
    expect every constructor here to be missing exactly that one field (plus the two
    deliberate [source] additions just above) and no other.

    {2 Wire tags}

    Each constructor is encoded as [Value.Sum (tag, Value.Record [...])], one stable
    string tag per constructor (documented below, next to each constructor), matching the
    domain-separation style already used by {!Riptide.Envelope.content_hash}. These tag
    strings, and each constructor's field names, are this module's actual wire format —
    changing either is a wire-format-breaking change, not a cosmetic rename.

    {2 Wire-integrity checksum (subtask 3.6)}

    The encoding produced by {!encode} is [Value.canonical_encode (to_value t)] followed by
    an 8-byte trailing checksum (the first 8 bytes of {!Riptide.Value.content_hash} of the
    encoded value); {!decode} recomputes and checks it before accepting the bytes.

    This is accidental-corruption detection, {b not authentication and not a security
    boundary}: VSR is a crash-fault-tolerant protocol, not a Byzantine one, and the
    network-corruption case this would originally have guarded against is already closed
    for every real deployment by {!Riptide_transport.Tcp}'s own mandatory mutual TLS
    (AES-GCM authenticated encryption fails closed on a tampered record before VSR ever
    sees the bytes). What this checksum catches instead is corruption introduced somewhere
    other than the network — a local encoding bug, or bytes already corrupted before
    retransmission — which keeps the DST test harness's own wire-corruption fault injection
    meaningful rather than silently accepted as a legitimately different value.

    A checksum failure raises {!Malformed_message}, the same exception every other
    malformed-input case here already raises. {!Riptide_vsr.Replica.handle_message} already
    catches {!Malformed_message} unconditionally and silently drops the message (relying on
    VSR's own retry/timeout machinery to recover) — this checksum required zero changes to
    that call site. *)

type t =
  | Prepare of { view : int; n : int; v : Riptide.Value.value; k : int; source : int }
      (** Tag ["Prepare"]. [v] is the client's proposed value (an arbitrary
          {!Riptide.Value.value}, not a numeric field — this is VSR.tla's own overloading of
          the name "v" for two different things: the client value here, vs. a view number
          in the other four constructors below).

          {b [source] is NOT transcribed from `spec/tla/VSR.tla`'s own [ReceiveClientRequest]
          record literal} — the abstract model has no need for it (its message-bag delivery
          already carries provenance implicitly). It is a deliberate, implementation-only
          addition (audit-remediation Task 3) closing the single highest-severity finding of
          the 2026-09-29 audit: with no sender field at all, a forged [Prepare] could rewrite
          any backup's log with no cross-check possible. [source] is always the sending
          replica's own id ({!Riptide_vsr.Replica.t}'s [my_id]) — {!Riptide_vsr.Replica.handle_message}
          cross-checks it against the transport-authenticated sender the underlying connection
          actually belongs to (see {!Riptide_transport.Transport_intf.S.receive}) before ANY
          per-message-type logic runs, exactly like the [i] field on [Prepare_ok]/
          [Start_view_change]/[Do_view_change] below is now also cross-checked, even though
          those already existed pre-Task-3. *)
  | Prepare_ok of { view : int; n : int; i : int }  (** Tag ["PrepareOk"]. *)
  | Start_view_change of { v : int; i : int }  (** Tag ["StartViewChange"]. [v] is a view number. *)
  | Do_view_change of {
      v : int;
      entries : (int * Riptide.Value.value) list;
      nacks : int list;
      last_normal_view : int;
      n : int;
      k : int;
      i : int;
    }
      (** Tag ["DoViewChange"]. [v] is a view number.

          {b [entries] and [nacks] replace the single [log] field an earlier version of this
          constructor carried}, transcribing [SendDVC]'s own record literal after
          `spec/tla/VSR.tla`'s storage-fault-aware extension (VSR.tla:376-389, and the
          explanation of why the evidence is piggybacked here rather than accumulated separately
          at VSR.tla:348-375):

          - [entries] is a {b partial} map from op-number to value — exactly the op-numbers this
            replica can actually READ ([ReadableEntries(r)], VSR.tla:170), so a slot whose
            checksum no longer verifies is simply not in it. It is deliberately not a list of
            values: "a replica cannot send bytes it cannot read", and a corrupt slot in the
            middle does not hide the readable slots after it, so the domain genuinely need not be
            a contiguous prefix. Encoded as [Sequence [ Record [ "o"; "v" ]; ... ]].
          - [nacks] is the set of op-numbers this replica can {b prove} it never durably held
            ([{ o \in ops : CanNack(r, o) }], VSR.tla:383 / :157). A corrupt slot is never in it
            — that is the single rule the whole nack-quorum truncation argument rests on
            (VSR.tla:112-147). Encoded as [Sequence] of [Int] scalars.
          - [n] is still the sender's own op-number, which it knows from durable superblock state
            even when some slot bodies are unreadable — so [n] is NOT the length of [entries],
            and a receiver must not check it as if it were. *)
  | Start_view of { v : int; log : Riptide.Value.value list; n : int; k : int; source : int }
      (** Tag ["StartView"]. [v] is a view number. The TLA+ spec's own [StartView] record
          literal (in [SendSV]) has no [i]/sender field either — but, exactly like [Prepare]'s
          own [source] above, this module adds one anyway (audit-remediation Task 3): a forged
          [Start_view] with no sender-authentication at all was the audit's single
          highest-severity finding (proven live to rewrite an entire cluster's committed log
          from one forged message), and [Start_view] is precisely the message type with the
          most to gain from spoofing since a receiver adopts its [log]/[n]/[k] wholesale. Always
          the sending replica's own id; cross-checked by {!Riptide_vsr.Replica.handle_message}
          against the transport-authenticated sender the same way [source] on [Prepare] is. *)

val claimed_sender : t -> int
(** [claimed_sender t] is the sending replica's own id as [t] itself claims it: [source] for
    [Prepare]/[Start_view], [i] for [Prepare_ok]/[Start_view_change]/[Do_view_change]. Added
    (audit-remediation Task 3 fix round, finding M2) to replace five near-identical, independently
    maintained inline projections that used to live at each of
    {!Riptide_vsr.Replica.handle_message}'s per-message-type cross-check branches. {b The match
    inside is deliberately EXHAUSTIVE, with no wildcard arm}: that is the actual point of this
    function, not just where it happens to live — a future sixth constructor added to {!t} without
    extending this match is a compile error, not a silent "which field is the sender?" decision
    deferred to whichever call site remembers to ask it. Every current caller of this needs
    exactly this value for exactly one purpose ({!Riptide_vsr.Replica.handle_message}'s
    attribution cross-check against the transport-authenticated sender), so keeping the projection
    itself total and centralized is what makes that guarantee -- "every message type's claimed
    sender is checked, none silently skipped" -- structural rather than a convention a reviewer
    has to re-verify by hand at every call site. *)

exception Malformed_message of string
(** Raised by {!decode} on any input that is not a well-formed encoding of one of the five
    constructors above: bytes that don't decode as a {!Riptide.Value.value} at all (wraps
    {!Riptide.Value.canonical_decode}'s own [Invalid_argument], carrying its message
    through), a [Sum] tag string that isn't one of the five known tags, a value whose
    top-level shape isn't [Sum (_, Record _)] at all, or a [Record] missing an expected
    field or carrying a field of the wrong shape (e.g. [view] present but not an [Int]
    scalar). Never raises [Invalid_argument] itself — that exception is fully absorbed and
    re-raised as [Malformed_message] so callers only need to handle one exception type. *)

val encode : t -> string
(** [encode t] converts [t] to its [Value.Sum (tag, Value.Record [...])] wire shape (see
    above) and canonically encodes that.

    Can raise [Invalid_argument] (M4, task-6 review): unlike {!decode} below, which is
    guaranteed never to, [encode] inherits {!Riptide.Value.canonical_encode}'s own raise
    on a duplicate-keyed [Record]/[Map] anywhere in the encoded shape - reachable here
    specifically via a caller-supplied payload [Value.value] (e.g. a [Prepare]'s or
    [Commit]'s embedded event payload) that itself contains one, not from anything this
    module constructs. *)

val decode : string -> t
(** [decode s] is the inverse of {!encode}. Raises {!Malformed_message} on any malformed
    or adversarial input, per that exception's own doc comment above — never raises
    [Invalid_argument], never loops, never crashes with an unhandled exception.

    An unrecognized EXTRA field in an otherwise well-formed [Record] is silently ignored,
    not rejected — [decode] only requires that every field this constructor actually reads
    be present with the right shape; it does not require the [Record] to contain nothing
    else. This is a deliberate forward-compatibility choice, not an oversight: a future
    protocol version could safely add a field an older [decode] simply drops. *)
