(** Wire format for VSR's five protocol message types (`spec/tla/VSR.tla`), built on
    {!Riptide.Value.canonical_encode}/{!Riptide.Value.canonical_decode} rather than a
    second, hand-rolled encoder.

    {2 Field lists}

    Each constructor's field list is transcribed verbatim from the record literals passed
    to `Send`/`Broadcast` in `spec/tla/VSR.tla` (checked directly against that file, not
    from memory) — [Prepare] from [ReceiveClientRequest], [Prepare_ok] from
    [ReceivePrepareMsg], [Start_view_change] from [TimerSendSVC], [Do_view_change] from
    [SendDVC], [Start_view] from [SendSV].

    {b [dest] is deliberately omitted from every constructor here.} It exists in the TLA+
    spec only because TLA+'s message-bag delivery model needs an explicit destination
    carried on the message value itself; in this implementation, the transport layer's own
    [send ~to_:int ...] argument (see `lib/transport/transport_intf.ml`'s [S.send]) already
    carries the destination, so encoding it a second time inside the message body would be
    redundant. A reader
    checking this module's field lists against the TLA+ spec's record literals should
    expect every constructor here to be missing exactly that one field and no other.

    {2 Wire tags}

    Each constructor is encoded as [Value.Sum (tag, Value.Record [...])], one stable
    string tag per constructor (documented below, next to each constructor), matching the
    domain-separation style already used by {!Riptide.Envelope.content_hash}. These tag
    strings, and each constructor's field names, are this module's actual wire format —
    changing either is a wire-format-breaking change, not a cosmetic rename. *)

type t =
  | Prepare of { view : int; n : int; v : Riptide.Value.value; k : int }
      (** Tag ["Prepare"]. [v] is the client's proposed value (an arbitrary
          {!Riptide.Value.value}, not a numeric field — this is VSR.tla's own overloading of
          the name "v" for two different things: the client value here, vs. a view number
          in the other four constructors below). *)
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
  | Start_view of { v : int; log : Riptide.Value.value list; n : int; k : int }
      (** Tag ["StartView"]. [v] is a view number. Deliberately has no [i] field — the TLA+
          spec's own [StartView] record literal (in [SendSV]) has none either. *)

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
    above) and canonically encodes that. *)

val decode : string -> t
(** [decode s] is the inverse of {!encode}. Raises {!Malformed_message} on any malformed
    or adversarial input, per that exception's own doc comment above — never raises
    [Invalid_argument], never loops, never crashes with an unhandled exception.

    An unrecognized EXTRA field in an otherwise well-formed [Record] is silently ignored,
    not rejected — [decode] only requires that every field this constructor actually reads
    be present with the right shape; it does not require the [Record] to contain nothing
    else. This is a deliberate forward-compatibility choice, not an oversight: a future
    protocol version could safely add a field an older [decode] simply drops. *)
