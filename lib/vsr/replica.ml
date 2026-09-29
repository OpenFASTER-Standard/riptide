(* lib/vsr/replica.ml -- see replica.mli for the full cross-check against spec/tla/VSR.tla,
   including exact line citations for every guard/effect transcribed below. *)

open Riptide

(* VSR.tla's own [rep_status] (VSR.tla:29): {"Normal", "ViewChange"}. Renamed [View_change] here
   only for OCaml's own constructor-casing convention -- no semantic change from the spec's own
   string literal. THIS task ([check_timeout]/[handle_message]'s new [Start_view_change] dispatch)
   is the first to actually construct [View_change] for real -- via [TimerSendSVC] and
   [ReceiveHigherSVC] below -- so the earlier plan's placeholder "unused constructor" witness
   binding that used to live here is gone: the compiler now sees [View_change] built for real, at
   multiple call sites, with no need for a dummy binding to justify its existence. *)
type status = Normal | View_change

(* A real replica id set -- VSR.tla's own [rep_recv_svc[r]] (VSR.tla:33) is typed [SUBSET
   replicas], a genuine set with [\cup]/[Cardinality] semantics (ReceiveMatchingSVC's own [@ \cup
   {m.i}], VSR.tla:201; SendDVC's own [Cardinality(rep_recv_svc[r]) >= f], VSR.tla:221) -- so the
   earlier plan's placeholder [int list] representation (justified there only by "never read by
   anything in this plan's scope") is replaced here, now that this task's own [try_send_dvc]
   genuinely needs both dedup (the same sender's StartViewChange arriving twice must not inflate
   the count) and [Cardinality]. *)
module Int_set = Set.Make (Int)

(* ---- the durable side: [Riptide_storage.Storage_intf.S], as a record of closures ----

   VSR.tla's storage-fault-aware extension makes durability part of the PROTOCOL, not an
   orthogonal concern a caller bolts on: [CrashRestart] (VSR.tla:671-690) is only meaningful
   because [rep_log]/[rep_op_number]/[rep_commit_number]/[rep_view_number]/[rep_last_normal_view]
   survive it, and [CanNack] (VSR.tla:157) is only sound because the storage layer can tell
   "never written" from "written, now unreadable". So [t] below owns a backend.

   WHY A RECORD OF CLOSURES RATHER THAN A FIRST-CLASS MODULE STORED IN [t]. [Storage_intf.S] has
   an abstract [type t], so storing "the module plus its value" inside [Replica.t] means either
   making [Replica.t] itself polymorphic in the backend's type ([('s) Replica.t], which infects
   every existing signature, every test, [Riptide_batch_commit], and the DST harness's own replica
   array for no behavioural gain) or packing an existential (a GADT wrapper, which buys exactly
   the same erasure this record buys, with more ceremony). The closure record erases the backend's
   type at the single point of construction -- {!storage_of_module} -- exactly the way this module
   already takes its transport as a value ([send : to_:int -> string -> unit]) rather than as a
   functor parameter. [Replica.t] stays monomorphic, as it is today.

   The field names, argument labels and doc semantics are verbatim {!Riptide_storage.Storage_intf.S};
   this record adds nothing and hides nothing. *)
type storage = {
  wal_append : op_number:int -> string -> unit;
  wal_read : op_number:int -> string option;
  wal_truncate_after : op_number:int -> unit;
  wal_highest_op_number : unit -> int;
  wal_highest_durable_op_number : unit -> int;
  superblock_write : string -> unit;
  superblock_read : unit -> string option;
}

let storage_of_module (type a) (module S : Riptide_storage.Storage_intf.S with type t = a) (backend : a)
    =
  {
    wal_append = (fun ~op_number bytes -> S.wal_append backend ~op_number bytes);
    wal_read = (fun ~op_number -> S.wal_read backend ~op_number);
    wal_truncate_after = (fun ~op_number -> S.wal_truncate_after backend ~op_number);
    wal_highest_op_number = (fun () -> S.wal_highest_op_number backend);
    wal_highest_durable_op_number = (fun () -> S.wal_highest_durable_op_number backend);
    superblock_write = (fun bytes -> S.superblock_write backend bytes);
    superblock_read = (fun () -> S.superblock_read backend);
  }

let volatile_storage () = storage_of_module (module Riptide_storage.Memory_storage) (Riptide_storage.Memory_storage.create ())

(* VSR.tla's own per-op tri-state [rep_storage[r][o]] (VSR.tla:77, :100-150), as read back through
   a real {!Riptide_storage.Storage_intf.S}. The mapping is the single most safety-critical piece
   of this file, so it is stated here once and used everywhere rather than re-derived per call
   site:

     [Present v] -- the slot is readable AND its bytes decode to a value ([Holds(r, o)]).
     [Corrupt]   -- the op-number is within the replica's own DURABLE op-number range, but the
                    backend will not return it (checksum mismatch, torn write, a ring slot already
                    recycled) or the bytes no longer decode. The replica holds SOMETHING here it
                    cannot verify, so it can neither ship it nor prove it never held it.
     [Absent]    -- the op-number is beyond everything this replica has durable evidence of, so it
                    can PROVE it never durably wrote an entry there ([CanNack], VSR.tla:157).

   [Storage_intf.S.wal_read] deliberately returns [None] for BOTH "never written" and "corrupt"
   (its own doc comment says so, and names this function as the thing that exists to tell them
   apart "using cross-replica evidence this single-node signature has no access to"). What
   disambiguates them here is the DURABLE op-number: [t.op_number] comes from the superblock, is
   written only AFTER the WAL entry it describes is durable, and therefore bounds exactly the
   range this replica has already promised to hold. The [max] with the backend's own
   [wal_highest_op_number] is the conservative direction and is deliberate: an entry physically on
   disk but not yet covered by the superblock (a crash between the two writes) is treated as
   CORRUPT rather than ABSENT, i.e. it is never nacked. Erring this way costs liveness only;
   erring the other way is precisely the mutation VSR.tla:118-147 records TLC breaking
   [NoCommittedOpProvablyAbsent] on at depth 6.

   WHY THIS ONE STAYS ON THE STRICT [wal_highest_op_number] while [create]'s and [restart]'s guards
   moved to [wal_highest_durable_op_number] (Task 13 re-review finding 2). Those two guards ask "is
   this backend virgin / did it hold anything at all?", and there the strict reading is UNSOUND: it
   answers "no" for a backend holding a slot whose header survived but whose data did not. This
   function asks a different question, and the strict reading is SOUND for it -- because of the [max
   t.op_number]. [CanNack] (VSR.tla:157) is exactly [o > rep_op_number[r]], so nacking an op above
   this replica's own durable [op_number] is precisely what the spec licenses: such an op was never
   acknowledged (the PREPAREOK is sent only after both the WAL and the superblock write).

   AND THE REASON THE CHOICE IS SAFE IS NOT THE ONE THIS COMMENT USED TO GIVE -- review finding M4. It
   claimed that switching to the durable reading "would change the DVC nack set -- a protocol
   observable". That is FALSE, and worth correcting rather than leaving as a plausible-sounding
   justification someone later builds on. The [nacks] field of a DoViewChange comes from
   [provable_nacks], whose scan horizon is itself [max t.op_number (wal_highest_op_number ())] -- i.e.
   exactly this function's own [Absent] threshold under the strict reading. So no op in the scanned
   range can read [Absent], and the set is EMPTY. Switching this function to the durable reading only
   RAISES that threshold, so the scanned range stays entirely below it and the set is still empty. The
   nack set is unchanged either way; there is no protocol observable here to preserve.

   The DECISION to keep the strict reading stands on its own, for two real reasons. First, the
   [Corrupt]/[Absent] boundary is unobservable today at every OTHER call site too (the empty nack set
   over exactly such a leftover slot is asserted on a real DoViewChange by
   [test_a_header_only_slot_above_the_superblock_is_not_discarded_and_is_never_nacked]):
   [readable_entries],
   [adopt_durable_log]'s prefix check, [restart]'s [readable_prefix], [primary_execute_op]'s readability
   check and [for_test_wal_read] all match [Corrupt] and [Absent] in ONE arm, so [provable_nacks] is
   the only reader that can tell them apart at all -- and it provably cannot, per the paragraph above.
   (A future reader that DOES need the distinction has to re-derive this argument; it is a property of
   today's call sites, not a law.) Second, and this is why strict is
   the right default rather than a coin flip: the [Some]/[None] split at the top of this function comes
   from [wal_read], which is specified against the strict reading, so pairing the tri-state's own
   boundary with the same reading keeps ONE notion of "readable" inside one function instead of mixing
   two. The durable reading would be strictly more conservative (a header-only slot above [op_number]
   would read [Corrupt] rather than [Absent]) and would be equally correct; it simply buys nothing that
   is observable, at the cost of making this function answer with two different accessors' notions of
   the durable range at once. *)
type slot_state = Present of Value.value | Corrupt | Absent

(* ---- I2: the genuinely different reasons a durable append can be refused ----
   [durable_append] used to catch EVERY [Invalid_argument] and report one undifferentiated
   "the backend refused this entry" to the protocol layer. Three unrelated conditions were
   arriving through that one arm, and the conflation was invisible because nothing counted them.
   It is not hypothetical: instrumenting the existing suite before this change recorded 317
   refusals across one `dune test --force`, of two different kinds (308 + 9), none of them
   observable anywhere.

     [Fault_injection_cap] -- {!Riptide_storage.Fault_injecting_storage}'s own deliberate
       ["faults_max exceeded"] guard (Task 6). This is not a storage failure at all: it is the
       fault INJECTOR refusing to inject more simultaneous corruption than the configured
       replication quorum could tolerate. Measured: 308 of the 317. Rounding it down to "the
       backend refused this entry" silently makes a sweep's EFFECTIVE fault rate lower than its
       configured one, with nothing anywhere to say so.
     [Entry_rejected] -- a backend that cannot store an entry of this size at all
       ({!Riptide_storage.File_storage} raises for anything larger than one aligned data slot).
       This is the only shape the original blanket catch actually documented, and the only one
       that genuinely means "this entry can never be durable here".
     [Out_of_sequence] -- the backend's own [wal_highest_op_number] is not [op_number - 1].
       Measured: 9 of the 317, and REACHABLE BY DESIGN rather than a programming error: when
       [adopt_durable_log] is refused partway through, it has already truncated and partially
       re-appended, so the durable log sits BELOW this replica's own [op_number] until a
       [StartView] repairs it, and every append until then is out of sequence. That degradation
       is safe (the gap reads back [Corrupt], never [Absent] -- see [slot_state] above), which is
       exactly why it must be visible rather than silently equated with the case above.

   SUBTASK 3.7 adds a fourth, and the first genuinely TRANSIENT one:

     [Eviction_blocked] -- {!Riptide_storage.File_storage}'s [?may_evict] predicate declining to let
       this append overwrite an entry the ring's owner still needs (the ring is fixed-size and
       nothing in this system ever truncates a committed prefix away, so every append past
       [ring_capacity] destroys an older, already-acknowledged entry). Unlike the three above, this
       one is not a statement that anything is wrong: the call is well-formed and the SAME
       [op_number] succeeds once the owner's predicate relents. It is backpressure -- the real
       signal that materialization has fallen behind the log -- which is why it must not be
       flattened into [Entry_rejected]'s "this entry can never be durable here".

   TASK 12 (audit-remediation Decision 3.3, closing Storage-Important-1) adds a fifth, and the
   first that is not an [Invalid_argument] at all -- and, alongside [Eviction_blocked], the second
   genuinely TRANSIENT one:

     [Storage_fault] -- a REAL, genuinely transient resource condition out of the backend:
       [Out_of_memory], or an [Eio.Io]/bare [Unix.Unix_error] wrapping one of exactly four errnos
       -- [ENOSPC] (disk full), [EDQUOT] (quota exceeded; OCaml's [Unix.error] has no symbolic
       constructor for this, so it is matched as [EUNKNOWNERR 122], its value on every Linux this
       runs on -- see {!Riptide_storage.File_storage}'s own Linux-only, io_uring-only stance),
       [EIO] (hardware I/O error), and [ENOMEM] (allocation failure at the syscall level). Before
       this task, none of these matched [classify_append_refusal] (which only ever looks at an
       [Invalid_argument]'s message), so they propagated straight out of [durable_append] as an
       unhandled exception -- a disk filling up under a live [File_storage] could kill the whole
       replica process instead of being refused like every other kind of append failure. It is
       caught by its OWN arm in [durable_append], after (not instead of) the [Invalid_argument]
       classification below, precisely so it stays a distinct signal rather than being folded into
       [Entry_rejected]'s "this entry can never be durable here" -- an ENOSPC, unlike a too-large
       entry, may well succeed on retry once space frees up (see [durable_append]'s own comment
       below for the test that actually exercises this, not just documents it).

       {b Deliberately NARROW, matching this same block's discrimination discipline for
       [Invalid_argument] above:} EVERY OTHER shape -- a bare [Sys_error] (OCaml's channel-based
       I/O uses it for ENOSPC too, but this module's storage layer never goes through a channel, so
       there is no real backend shape to classify here, and a bare [Sys_error] is far more often a
       genuine bug, e.g. a format-string mismatch, than a storage refusal), any [Eio.Io] wrapping an
       errno OTHER than the four above (a permission change mid-run, an already-closed file
       descriptor, ...), or any [Eio.Io] wrapping a classified {!Eio.Fs.error} at all (e.g.
       [Not_found]/[Permission_denied]) -- PROPAGATES, exactly like an unrecognized
       [Invalid_argument] does below. An unrecognized exception out of a backend is a contract
       violation, not a documented storage refusal, and laundering it into "safe to retry" would be
       the same conflation this whole block exists to close, just moved one exception family over.
       [Unix.Unix_error] (not wrapped in [Eio.Io]) is matched with the same four-errno narrowness
       too, even though no backend in this repo raises it directly today ({!Riptide_storage.File_storage}'s
       own errors are all wrapped into [Eio.Io] by eio_linux; {!Riptide_storage.Memory_storage} and
       {!Riptide_storage.Fault_injecting_storage} raise [Invalid_argument]) -- it is the shape any
       FUTURE backend built directly on OCaml's [Unix] module (the way
       {!Riptide_storage.File_kv_store} already is, elsewhere in this codebase) would naturally
       produce, and there is no reason to leave that predictable future case unclassified when the
       classification is identical either way.

   HONEST DISCLOSURE, because [Storage_fault] is NOT the same safe "total no-op" guarantee the
   other four refusals get: {!Riptide_storage.File_storage.wal_append} writes a slot's header, then
   its data, as two SEPARATE, non-atomic writes. A [Storage_fault] raised between them (order is a
   real, load-bearing fact about the backend, not an implementation detail) leaves the slot's PRIOR
   occupant's header already overwritten while its data (or, symmetrically, a NEW header already
   written over an old one whose data write then fails) is not -- so that prior entry now reads back
   [Corrupt] (a checksum mismatch, per [wal_read]/[slot_state] above), permanently, even if it was
   below a [?may_evict] watermark that had refused to let it be evicted moments earlier. This is
   categorically worse than the other four refusals' guarantee (nothing written, nothing else
   disturbed) -- it is disclosed here, not hidden behind a claim of parity, matching
   [adopt_durable_log]'s own disclosure of its partial-rewrite case below for the identical reason:
   a real, narrower guarantee stated plainly is worth more than a broad one that is not actually
   true for every case it is asserted to cover.

   All five still mean "not durable" to the protocol, and the protocol still behaves identically
   -- the replica declines to acknowledge. What changes is that they are told apart and COUNTED
   (see [append_refusals]), so a harness -- or, since subtask 3.7, a real caller -- can assert on
   them, and that an Invalid_argument matching NONE of the first four now propagates instead of
   being swallowed: an unrecognized [Invalid_argument] out of a backend is not a documented storage
   refusal, and treating it as one is the very conflation this finding names. *)
type append_refusal =
  | Fault_injection_cap
  | Entry_rejected
  | Out_of_sequence
  | Eviction_blocked
  | Storage_fault

let append_refusal_kinds =
  [ Fault_injection_cap; Entry_rejected; Out_of_sequence; Eviction_blocked; Storage_fault ]

let append_refusal_index = function
  | Fault_injection_cap -> 0
  | Entry_rejected -> 1
  | Out_of_sequence -> 2
  | Eviction_blocked -> 3
  | Storage_fault -> 4

let append_refusal_name = function
  | Fault_injection_cap -> "fault_injection_cap"
  | Entry_rejected -> "entry_rejected"
  | Out_of_sequence -> "out_of_sequence"
  | Eviction_blocked -> "eviction_blocked"
  | Storage_fault -> "storage_fault"

(* Matched on the message, because [Storage_intf.S] has no dedicated exception for any of these
   and giving it one is a contract change to every backend and every conformance test -- out of
   scope for this fix. The two [wal_append: ] prefixes are raised verbatim, from one shared format
   string each, by BOTH {!Riptide_storage.Memory_storage} and {!Riptide_storage.File_storage};
   ["faults_max exceeded"] is raised verbatim from two sites in
   {!Riptide_storage.Fault_injecting_storage}. The fourth,
   ["wal_append: eviction blocked for op_number "] (subtask 3.7), is raised from one site in
   {!Riptide_storage.File_storage} only -- it is that module's [?may_evict] gate, and
   {!Riptide_storage.Memory_storage} has no ring to evict from. All four are pinned by
   [test_vsr_replica_recovery.ml]'s own discrimination test, which asserts the real exceptions
   those modules raise land in the intended buckets -- so a message reworded on either side fails
   a test rather than silently falling through to the propagating arm.

   The two ["wal_append: "] prefixes that share a first word are disjoint by construction:
   ["wal_append: op_number "] is followed by a digit, ["wal_append: eviction blocked for op_number "]
   never reaches that arm because it does not start with ["wal_append: op_number "]. Order is
   therefore not load-bearing here, but the prefixes are deliberately long enough that it never
   becomes so. *)
let classify_append_refusal msg =
  if String.equal msg "faults_max exceeded" then Some Fault_injection_cap
  else if String.starts_with ~prefix:"wal_append: entry of " msg then Some Entry_rejected
  else if String.starts_with ~prefix:"wal_append: op_number " msg then Some Out_of_sequence
  else if String.starts_with ~prefix:"wal_append: eviction blocked for op_number " msg then
    Some Eviction_blocked
  else None

(* One received DOVIEWCHANGE, as an element of VSR.tla's own [rep_recv_dvc[r]] (VSR.tla:34, typed
   [SUBSET [message]] -- a set of message RECORDS). Exactly the six fields [SendDVC]'s own record
   literal carries (VSR.tla:222-224), minus [type]/[dest] (constant/implied here -- see
   message.mli's own note on why [dest] is not on the wire at all in this implementation).

   Why a dedicated record rather than storing the decoded [Message.t] variant itself (the shape
   task-3-brief.md sketches as "e.g. [(int, Message.t) Hashtbl.t]"): the two are equivalent in
   content, but every reader below ([winning_dvc], [highest_commit_number], [valid_dvc]) wants the
   six fields directly, and a [Message.t] would force each of them to re-match the variant and
   handle four constructor cases that [receive_dvc] structurally never inserts -- an unreachable
   catch-all arm in the single highest-risk function in this module. Keying and first-wins
   semantics (the actual substance of that brief decision) are unchanged; see
   [handle_do_view_change] below. *)
type dvc = {
  dvc_v : int;
  dvc_entries : (int * Value.value) list;
      (* [ReadableEntries(r)] (VSR.tla:170) as shipped by [SendDVC] (VSR.tla:381-382): a PARTIAL
         map, op-number -> value, defined exactly on the slots the sender could read. NOT a list
         of values and NOT necessarily a contiguous prefix -- a corrupt slot does not hide the
         readable slots after it. Validated on arrival to have every op-number within [1, dvc_n]
         and no duplicates (see [handle_do_view_change]), so every reader below may index it
         freely. *)
  dvc_nacks : int list;
      (* [{ o \in ops : CanNack(r, o) }] (VSR.tla:383): op-numbers the sender PROVES it never
         durably held. Validated on arrival to be positive and strictly greater than [dvc_n] --
         see [handle_do_view_change]'s own guard for why a nack at or below the sender's own
         op-number is a self-contradiction rather than merely unusual. *)
  dvc_last_normal_view : int;
  dvc_n : int;
  dvc_k : int;
  dvc_i : int;
}

type t = {
  my_id : int;
  replica_count : int;
  svc_limit : int; (* StartViewOnTimerLimit -- bounds check_timeout; read by check_timeout
                       itself, below in this same file. *)
  log : Replica_log.t;
  (* The in-memory, fast-path copy of [rep_log[r]]. The DURABLE copy lives in [storage]'s WAL and
     is authoritative across a restart; this one is what a running process reads. They advance
     together (every append/adoption writes both), with exactly one documented way for them to
     differ: after a restart that discovered a corrupt slot, this holds only the READABLE PREFIX
     of the durable log, while [op_number] below still carries the full durable op-number. See
     [restart]. *)
  storage : storage;
  mutable op_number : int;
  (* VSR.tla's [rep_op_number[r]] (VSR.tla:52), now a field of its own rather than (as before this
     task) a synonym for [Replica_log.length t.log]. It has to be: [rep_op_number] is DURABLE
     across [CrashRestart] (VSR.tla:592-593) and comes back from the superblock, whereas the
     in-memory log after a restart may be shorter than it -- and SendDVC's own comment
     (VSR.tla:358-359) turns on exactly that distinction: "n -- its op-number, which it still
     knows from durable superblock state even when some slot bodies are unreadable". Keeping the
     two in lockstep is now this module's own obligation ([LogLengthMatchesOpNumber],
     VSR.tla:728-729, holds whenever the log has no unreadable slot); every writer below updates
     both in the same step. *)
  mutable status : status; (* VSR.tla's [rep_status[r]] (VSR.tla:29). *)
  mutable view_number : int; (* VSR.tla's [rep_view_number[r]] (VSR.tla:30), i.e. [View(r)]. *)
  mutable last_normal_view : int;
  (* VSR.tla's [rep_last_normal_view[r]] (VSR.tla:31) -- the paper's [v'], deliberately NOT
     derivable from [view_number]. Read by try_send_dvc (below, DoViewChange's own
     last_normal_view field); still only ever WRITTEN by test-support code in this task's own
     scope -- SendSV/ReceiveSV (a later task) are the real writers. *)
  mutable commit_number : int;
  mutable recv_svc : Int_set.t;
  (* VSR.tla's [rep_recv_svc[r]] (VSR.tla:33) -- STARTVIEWCHANGE senders for the current
     view-change episode. Written by [check_timeout] (reset to empty, TimerSendSVC, VSR.tla:168),
     [handle_start_view_change]'s two branches (seeded to a singleton, ReceiveHigherSVC,
     VSR.tla:189; unioned, ReceiveMatchingSVC, VSR.tla:201), and read by [try_send_dvc]
     (Cardinality, SendDVC, VSR.tla:221). *)
  recv_dvc : (int, dvc) Hashtbl.t;
  (* VSR.tla's [rep_recv_dvc[r]] (VSR.tla:34) -- the DOVIEWCHANGE messages received this episode.
     Reset to empty by [check_timeout]/[handle_start_view_change]'s ReceiveHigherSVC branch (both
     begin a new view-change episode, VSR.tla:169, 190) and populated by [handle_do_view_change]
     ([ReceiveDVC], VSR.tla:232-240). Read only by [try_send_sv] ([SendSV], VSR.tla:264-280).

     DELIBERATE, DISCLOSED DIVERGENCE from a literal transcription of VSR.tla:34's own
     [SUBSET [message]] type, resolved by task-3-brief.md and reproduced here so the reasoning
     lives next to the code: this is a table KEYED BY SENDER ([m.i]), not a set of message records.
     In the abstract model a set-of-records is safe, because a correct replica sends exactly one
     DOVIEWCHANGE per view-change episode ([rep_sent_dvc]'s own one-shot semantics on the sending
     side) and TLA+'s message bag cannot corrupt anything -- so "one element per sender" and "one
     element per distinct record" coincide. Neither premise survives contact with this codebase's
     real simulated transport: [lib/sim/network.ml] injects both [duplicate_probability] AND
     [corrupt_probability], so the same sender's DOVIEWCHANGE can arrive twice with DIFFERENT bytes
     (one pristine copy, one independently corrupted copy). Under a literal set-of-records those
     are two distinct elements, and [SendSV]'s own [Cardinality(...) >= f + 1] threshold
     (VSR.tla:269) would count ONE sender twice -- while VSR.tla:262-263's own citation requires
     "f+1 DOVIEWCHANGE from DIFFERENT replicas, including itself". Counting messages instead of
     senders is a literal reading of the TLA+ text and the WRONG semantics for a real adversarial
     network: it is the historical 114-step-counterexample bug class (quorum inflation during view
     change) reached by a different route.

     FIRST-WINS, NOT LAST-WINS: once a sender has an entry for the CURRENT episode, every later
     arrival from that same sender is ignored -- a genuine retransmission, a duplicate-injected
     copy, and a corrupted duplicate are indistinguishable at this layer, so the rule that keeps
     the most trustworthy state is "keep the first, never let a later arrival overwrite an earlier
     one". Last-wins would let a single corrupted duplicate replace an already-accepted, valid DVC
     (its [log]/[n]/[k] are what [WinningDVC]/[HighestCommitNumber] then select over). See
     [handle_do_view_change] below for the one nuance: an entry left over from an OLDER view (only
     reachable via [ReceiveSV], the sole action that raises [view_number] without clearing this
     table) is NOT protected by first-wins, since it does not belong to the current episode at
     all. *)
  mutable sent_dvc : bool;
  (* VSR.tla's [rep_sent_dvc[r]] (VSR.tla:35) -- the one-shot "already sent my DOVIEWCHANGE for
     this episode" flag [SendDVC] (VSR.tla:216-228) is gated on. Reset to [false] by
     [check_timeout]/[handle_start_view_change]'s ReceiveHigherSVC branch (both begin a new
     episode) and set [true] by [try_send_dvc] once it actually fires. *)
  mutable svc_count : int;
  (* VSR.tla's [aux_svc_count[r]] (VSR.tla:41) -- bounds [check_timeout] (TimerSendSVC,
     VSR.tla:161-174), incremented every time it fires. VSR.tla's own [aux_svc_count] is a pure
     state-space-bounding device for TLC (research §6.3 point 4) and is NEVER reset anywhere in the
     abstract spec -- transcribed literally, a real replica would permanently stop trying to
     trigger a view change after [svc_limit] timeouts, forever, which is clearly wrong for a real
     long-running deployment that needs to recover from repeated primary failures.

     DELIBERATE, DISCLOSED DIVERGENCE from the literal TLA+ transcription (an earlier task's own
     review ruling, not an oversight): [svc_count] must reset to [0] whenever this replica
     successfully returns to [Normal] status by actually COMPLETING a view change -- either by
     calling [SendSV] itself (becoming the new primary) or via [ReceiveSV] (accepting a new
     primary's [StartView]) -- since at that point the replica has proven it can reach a working
     view, and any FUTURE timeout represents a genuinely new failure deserving its own fresh
     budget. BOTH resets are now implemented, in [try_send_sv] and [handle_start_view] below, at
     the exact point each action sets [status' = "Normal"] (VSR.tla:275, 301).

     The two are NOT symmetric, and the asymmetry is deliberate (task-3-brief.md's own resolved
     design decision 3): [SendSV]'s guard already requires [rep_status[r] = "ViewChange"]
     (VSR.tla:267), so its reset is unconditional and can only ever fire on a real
     View_change -> Normal transition. [ReceiveSV]'s guard is [m.v >= View(r)] (VSR.tla:295 --
     [>=], not [>]) with NO status conjunct at all, so it genuinely fires on a duplicate or
     replayed [StartView] for the view this replica is ALREADY Normal in. Resetting [svc_count]
     unconditionally there would let a stream of duplicate [StartView]s (not hypothetical --
     [lib/sim/network.ml] has a real [duplicate_probability]) refresh this replica's timeout budget
     indefinitely, silently nullifying the [svc_limit] bound the whole mechanism exists to enforce.
     [handle_start_view] therefore resets only on an actual [View_change -> Normal] transition. *)
  (* Primary-only bookkeeping (VSR.tla's [rep_peer_op_number[r]]) -- harmless, simply never
     populated, on a backup. Keyed by peer replica id, value is that peer's highest acknowledged
     op-number (a cumulative high-water mark, never regressed -- see handle_prepare_ok).
     INVARIANT, maintained solely by handle_prepare_ok's own range check below: every key in this
     table is always a valid replica id in [1, replica_count] (VSR.tla's own [replicas ==
     1..ReplicaCount], VSR.tla:15) -- a decoded [Prepare_ok]'s [i] field that falls outside that
     range is rejected before it ever reaches this table, never merely filtered out later when
     read. Enforcing at the single point of INSERTION rather than at each read is deliberate: it
     gives the invariant exactly one enforcement site that a new reader cannot forget to repeat,
     so [is_committed_quorum] below (and any future reader -- view-change will add more) may take
     "every key here is a real replica id" as given instead of re-deriving it. A range check
     scattered across readers is one missed reader away from the same quorum-inflation bug it was
     added to prevent. *)
  peer_op_number : (int, int) Hashtbl.t;
  send : to_:int -> string -> unit;
  on_commit_advanced : (old_commit:int -> new_commit:int -> unit) option;
      (* Subtask 3.7: the domain-agnostic commit-progress hook, supplied (or not) at [create] time
         and never reassigned afterwards -- hence immutable. Deliberately typed over two plain
         [int]s: [Replica] is Layer 0 and must not learn anything about what a consumer does with
         commit progress (Task 6's ring-eviction watermark is the first one). [None] is the
         zero-cost default every pre-existing caller gets.

         Invoked ONLY through [advance_commit_number] below, which is the single writer of
         [commit_number] in this module and the one place the "exactly once per genuine INCREASE"
         contract documented in replica.mli is enforced. It has to be enforced THERE rather than
         inherited from the call sites: three of the four sites do guard on a strict increase, but
         [try_send_sv]'s does NOT -- VSR.tla:508's [rep_commit_number' = HighestCommitNumber(r)] is
         unconditional and genuinely lowers [commit_number] in a real, tested scenario (see
         [test_send_sv_commit_number_assignment_is_unconditional_not_monotonic] and
         [test_on_commit_advanced_does_not_fire_on_sendsv_commit_number_decrease] in
         test_vsr_replica.ml). Reporting that decrease as an "advance" would drive a watermark
         consumer backwards. *)
  append_refusals : int array;
      (* I2: one counter per {!append_refusal}, indexed by [append_refusal_index]. Pure
         diagnostics -- nothing in the protocol ever reads it -- but it is what makes the three
         refusal shapes told apart above OBSERVABLE rather than merely distinguished in a comment.
         See [append_refusals]. *)
}

(* ---- the superblock record: VSR.tla's DURABLE per-replica state ----
   [CrashRestart]'s own list (VSR.tla:592-596), minus the log itself (which lives in the WAL):
   [rep_op_number], [rep_commit_number], [rep_view_number], [rep_last_normal_view]. The last two
   are the point of Decision 4 -- persisted rather than reconstructed by VSR's textbook in-memory
   Recovery sub-protocol -- and [rep_status] is deliberately NOT among them: it is RECONSTRUCTED
   from [view > log_view] at restart (VSR.tla:596-597, :680-682), which is exactly what the
   durable pair buys.

   Encoded with {!Riptide.Value.canonical_encode}, the same primitive {!Message} uses, rather than
   a second hand-rolled format.

   TASK 13 FIX ROUND (review finding 5): the encode/decode pair below no longer OWNS that schema --
   it DELEGATES to {!Riptide_storage.Superblock_record}, the single definition of it in this repo.
   The four field names and shapes used to be typed out independently here, in
   [lib/storage/file_storage.ml] and in [lib/storage/memory_storage.ml], because
   [riptide_storage] cannot depend on [riptide_vsr]. The dependency direction is real (see either
   [dune]), but the conclusion did not follow: BOTH layers need this schema, so the one place it can
   live once is the LOWER one, and a field rename can no longer leave a rebuild silently producing
   records this decoder rejects. What stays here is what is genuinely protocol knowledge -- which
   fields VSR's own [CrashRestart] considers durable, and why [rep_status] is not among them.

   Kept as named functions in this module rather than having every call site reach into
   [Superblock_record] directly: [replica.mli] documents these two by name, and the tuple shape
   below ([restart] destructures it positionally) is this module's own convenience, not part of the
   shared schema. *)
let superblock_encode ~view_number ~last_normal_view ~op_number ~commit_number =
  Riptide_storage.Superblock_record.encode
    { Riptide_storage.Superblock_record.view_number; last_normal_view; op_number; commit_number }

(* Tolerant by construction: anything that does not decode as the exact record shape above yields
   [None], i.e. "this replica has no usable durable state", never an exception. A superblock that
   fails to read back is the storage layer's own already-documented failure mode
   ({!Riptide_storage.Storage_intf.S.superblock_read} returns [None] when fewer than a majority of
   its copies agree), and a partially-decodable one is no more trustworthy than a missing one. The
   [commit_number <= op_number] clause ([CommitNumberNeverHigherThanOpNumber], VSR.tla:721-722,
   applied to durable state as it is READ BACK and not merely as it is written) is part of
   {!Riptide_storage.Superblock_record.decode} itself, which is where that rule now lives. *)
let superblock_decode (bytes : string) =
  Option.map
    (fun (r : Riptide_storage.Superblock_record.t) ->
      (r.view_number, r.last_normal_view, r.op_number, r.commit_number))
    (Riptide_storage.Superblock_record.decode bytes)

let persist_superblock t =
  t.storage.superblock_write
    (superblock_encode ~view_number:t.view_number ~last_normal_view:t.last_normal_view
       ~op_number:t.op_number ~commit_number:t.commit_number)

let validate_create_args ~fn ~my_id ~replica_count ~svc_limit =
  if replica_count < 1 then invalid_arg (fn ^ ": replica_count must be >= 1");
  if replica_count mod 2 = 0 then
    invalid_arg
      (fn
     ^ ": replica_count must be odd -- VSR.tla:140's own comment assumes 2f+1 = ReplicaCount, and \
        VSR.cfg never instantiates an even count");
  if my_id < 1 || my_id > replica_count then
    invalid_arg (fn ^ ": my_id must be in [1, replica_count] (VSR.tla's replicas == 1..ReplicaCount)");
  if svc_limit < 1 then
    invalid_arg
      (fn
     ^ ": svc_limit must be >= 1 -- VSR.tla:163's own [aux_svc_count[r] < StartViewOnTimerLimit] \
        guard on TimerSendSVC is never satisfiable at aux_svc_count[r] = 0 (Init's own starting \
        value) for a non-positive limit, which would permanently and silently disable view-change \
        from ever starting on this replica")

(* The shared skeleton of [create] and [restart]: everything VOLATILE is at its [Init] value here
   (VSR.tla:198-214), and the caller supplies whatever DURABLE state it has -- zeros for [create],
   the superblock's contents for [restart]. Keeping this in one place is what makes the
   durable/volatile split auditable in one read rather than by diffing two constructors:
   [CrashRestart] (VSR.tla:599-601) resets exactly [rep_peer_op_number], [rep_recv_svc],
   [rep_recv_dvc] and [rep_sent_dvc], and every one of them is initialized below, unconditionally,
   for both entry points. *)
let make ~my_id ~replica_count ~svc_limit ~send ~storage ~view_number ~last_normal_view ~op_number
    ~commit_number ~status ~on_commit_advanced =
  {
    my_id;
    replica_count;
    svc_limit;
    log = Replica_log.create ();
    storage;
    op_number;
    status;
    view_number;
    last_normal_view;
    commit_number;
    recv_svc = Int_set.empty;
    recv_dvc = Hashtbl.create (max 1 replica_count);
    sent_dvc = false;
    svc_count = 0;
    peer_op_number = Hashtbl.create (max 1 (replica_count - 1));
    send;
    on_commit_advanced;
    append_refusals = Array.make (List.length append_refusal_kinds) 0;
  }

(* The SINGLE writer of [t.commit_number] in this module (verified: [grep 'commit_number <-'] finds
   exactly this one assignment). Every action that advances commit progress goes through here, which
   is what makes [?on_commit_advanced] impossible to forget when a future action is added.

   The [new_commit > old_commit] gate is load-bearing, not defensive padding -- see the
   [on_commit_advanced] field's own comment above for the real, tested [try_send_sv] decrease it
   exists to filter out. The ASSIGNMENT stays unconditional, exactly as each of the four call sites
   had it before this hook existed: this helper changes only what is OBSERVED, never what is
   stored, so no protocol behaviour moves. *)
let advance_commit_number t new_commit =
  let old_commit = t.commit_number in
  t.commit_number <- new_commit;
  if new_commit > old_commit then
    match t.on_commit_advanced with None -> () | Some f -> f ~old_commit ~new_commit

let create ?on_commit_advanced ~my_id ~replica_count ~svc_limit ~send ~storage () =
  validate_create_args ~fn:"Replica.create" ~my_id ~replica_count ~svc_limit;
  (* [wal_highest_durable_op_number], not [wal_highest_op_number] (Task 13 re-review finding 2).
     The question this guard asks is "is this backend VIRGIN?", and a backend holding one slot whose
     header survived a crash while its data did not is not virgin, even though nothing in it can be
     read back. Under the strict reading such a backend passes this guard, [create] writes a fresh
     [Init] superblock over it, and the replica comes up claiming [op_number = 0] over durable
     evidence of ops it really did accept -- proving them absent, the exact hazard
     [restart]'s own fail-stop guard below exists to stop, reached through [create] instead. *)
  if storage.wal_highest_durable_op_number () > 0 || storage.superblock_read () <> None then
    invalid_arg
      "Replica.create: this storage backend already holds durable state -- use Replica.restart to \
       recover it (VSR.tla's CrashRestart, :671-690), never Replica.create, which would silently \
       discard the durable view_number/last_normal_view pair the whole recovery mechanism is built \
       on";
  let t =
    make ~my_id ~replica_count ~svc_limit ~send ~storage ~view_number:0 (* VSR.tla's [Init] (:206) *)
      ~last_normal_view:0 ~op_number:0 ~commit_number:0 ~status:Normal ~on_commit_advanced
  in
  (* Claim the backend immediately, so this replica's very first durable state is a well-formed
     superblock rather than "nothing at all" -- otherwise a crash before the first client request
     would leave [restart] unable to tell an initialized replica from an empty disk. *)
  persist_superblock t;
  t

(* [Primary(v) == 1 + ((v-1) % ReplicaCount)] (VSR.tla:18), for an ARBITRARY view [v] -- not
   necessarily this replica's own {!view_number}. Finding 3 of the audit-remediation Task 3 fix
   round needs exactly this: [handle_start_view]'s message carries its OWN [v] field (the view
   being switched TO, which need not equal the receiver's current {!view_number} -- VSR.tla:295's
   guard is [m.v >= View(r)], not [m.v = View(r)]), so checking "is the sender really Primary of
   the view this message is ABOUT" requires computing [Primary] of that message's [v], not of
   [t]'s own current one. [primary] below is now a thin wrapper over this for the common case
   (checking against THIS replica's own current view).

   TLA+'s [%] is Euclidean (floored) modulo, always non-negative; OCaml's [mod] follows the sign
   of the DIVIDEND, so [(v-1) mod replica_count] can itself be negative when [v = 0] (or any [v <=
   0]). Normalized to the Euclidean result via [(x mod n + n) mod n] -- computationally verified
   against TLC's own already-established values (both in the TLA+ spec plan and again for this
   plan) before being written here: at [replica_count = 3], this formula gives [Primary(0) = 3],
   [Primary(1) = 1], [Primary(2) = 2]. See replica.mli's own note on why [Primary(0) = 3], NOT
   [1], is the trap this normalization exists to avoid. *)
let primary_of_view ~replica_count v = 1 + (((v - 1) mod replica_count + replica_count) mod replica_count)

let primary t = primary_of_view ~replica_count:t.replica_count t.view_number

let is_primary t = t.my_id = primary t
let op_number t = t.op_number
let commit_number t = t.commit_number
let view_number t = t.view_number
let last_normal_view t = t.last_normal_view
let status t = t.status
let entries t = Replica_log.to_list t.log

(* ---- Test-support surface: NOT part of the protocol. ----
   [t] is abstract, and the real protocol never lets anything other than the view-change actions
   themselves (TimerSendSVC / ReceiveHigherSVC / ReceiveMatchingSVC, implemented below in this
   same file; SendSV / ReceiveSV, a later task) move [view_number]. Tests, though, need a way to
   put a chosen replica id at [primary t]
   without either hand-deriving [Primary(v)] at every call site or waiting for view-change to
   exist. See replica.mli's own doc comment on this function for the exact convention it
   establishes (view_number = 1 always makes replica id 1 the primary, regardless of
   replica_count, since Primary(1) = 1 + ((1-1) mod replica_count) = 1 for any replica_count).

   Also sets [last_normal_view] to the same value [v] -- NOT left untouched. Fix-round finding M3
   (task-1-review.md): a fresh TLC run of a copy of VSR.tla with the added invariant
   [status[r] = "Normal" => last_normal_view[r] = view_number[r]] found ZERO violations across
   264,376 distinct reachable states, so [status = Normal /\ last_normal_view <> view_number] is
   genuinely unreachable in the real protocol -- every spec action that (re-)enters "Normal"
   ([SendSV], VSR.tla:275-276; [ReceiveSV], VSR.tla:301-302) sets [rep_last_normal_view] to the
   new view in the SAME step, and every action that raises [view_number] moves [status] to
   "ViewChange" first (VSR.tla:166-167, 187-188), so the two are never allowed to be Normal and
   mismatched simultaneously. Leaving [last_normal_view] stale here would let every test built on
   this setter silently validate against a protocol-impossible state -- harmless while nothing
   reads [last_normal_view] (this task's own scope), but Task 2/3's [WinningDVC] (VSR.tla:248-255)
   selects the surviving log by [last_normal_view] FIRST, so a falsely-stale value there would
   corrupt exactly the highest-risk logic in the whole plan. Keeping the two fields in sync by
   default is the only reachable choice; a test that genuinely needs them to differ (e.g. to
   construct a mid-view-change state) should use {!for_test_set_view} below, its own, separate
   test-support constructor, rather than repurposing this one. *)
let for_test_set_view_number t v =
  t.view_number <- v;
  t.last_normal_view <- v;
  (* Both fields are DURABLE (VSR.tla:58-62), so a setter that moved them only in memory would
     leave [t] in a state no real transition can produce and, worse, one that {!restart} would
     silently undo. Persisting here keeps every route to a given state -- real action or test
     setter -- agreeing about what is on disk. *)
  persist_superblock t

(* Prescribed by replica.mli's own note on [for_test_set_view_number] (task-1-review.md's M3
   fix-round finding): [for_test_set_view_number] is correct ONLY for [status = Normal] (it forces
   [last_normal_view = view_number] in lockstep, matching the spec's confirmed
   [status = "Normal" => last_normal_view = view_number] invariant) -- reusing it to build a
   [View_change]-status test state would silently construct the exact mirror-image bug that
   fix-round finding fixed for the Normal case: a [View_change]-status replica's [last_normal_view]
   is very often DIFFERENT from its [view_number] (that is the whole point of the field -- see
   VSR.tla:31's own comment, "the paper's v', NOT derivable from rep_view_number"), so a setter that
   force-synced the two would make it impossible to construct the realistic test states
   [WinningDVC] (VSR.tla:248-255) itself depends on selecting between. This setter therefore sets
   all three fields directly and independently, with no synchronization -- the caller is
   responsible for choosing a combination that is actually reachable if that matters for what it's
   testing. *)
let for_test_set_view t ~status:s ~view_number ~last_normal_view =
  t.status <- s;
  t.view_number <- view_number;
  t.last_normal_view <- last_normal_view;
  (* Persisted for the same reason as {!for_test_set_view_number} above. Note [status] itself is
     deliberately NOT persisted -- it is not durable state at all; a restart RECONSTRUCTS it from
     [view_number > last_normal_view] (VSR.tla:680-682), so setting a status here that contradicts
     that pair is a test-only state that will not survive a {!restart}, by design. *)
  persist_superblock t

(* [Value.value] identity for dedup/is_committed purposes: canonical-encoding equality, not
   OCaml's structural [=] -- see replica.mli's own doc comment on [propose] for why (lib/value.mli's
   [Float] case is content-addressed by raw bit pattern, not by OCaml's [=]/[compare]). *)
let value_equal (a : Value.value) (b : Value.value) = Value.canonical_encode a = Value.canonical_encode b

(* ============================================================================================
   The durable side, part 2: the operations every protocol action below goes through. Nothing in
   this module calls [t.storage.*] outside this block, so the guards here are the ONLY guards
   needed -- the pattern [peer_op_number]'s own doc comment establishes for [handle_prepare_ok]'s
   range check ("one enforcement site a new reader cannot forget to repeat"), applied to storage.
   ============================================================================================ *)

(* VSR.tla's [rep_storage[r][o]] as read back from a real backend -- see [slot_state]'s type
   declaration at the top of this file for the full mapping and its safety argument. *)
let slot_state t ~op_number : slot_state =
  if op_number < 1 then Absent
  else
    match t.storage.wal_read ~op_number with
    | Some bytes -> (
      match Value.canonical_decode bytes with
      | v -> Present v
      | exception Invalid_argument _ ->
        (* Readable bytes that are not a decodable value: the backend's own checksum passed but
           the entry is not usable, which is "holds something I cannot verify" -- corrupt, never
           absent. *)
        Corrupt)
    | None -> if op_number <= max t.op_number (t.storage.wal_highest_op_number ()) then Corrupt else Absent

(* [ReadableEntries(r)] (VSR.tla:170), materialized as the partial map [SendDVC] ships
   (VSR.tla:381-382). Deliberately not a prefix scan: a corrupt slot does not hide the readable
   slots after it, and "a replica that can read op 2 but not op 1 is a real state this model must
   be able to express". *)
let readable_entries t =
  let rec loop o acc =
    if o < 1 then acc
    else loop (o - 1) (match slot_state t ~op_number:o with Present v -> (o, v) :: acc | Corrupt | Absent -> acc)
  in
  loop t.op_number []

(* [{ o \in ops : CanNack(r, o) }] (VSR.tla:383, :157) restricted to the op-numbers this replica
   has any durable trace of.

   DISCLOSED AND DELIBERATE, because it is the one place this transcription's shape differs
   visibly from the spec's: VSR.tla quantifies over [ops == 1..MaxOp], a bounded universe the
   model has and a real replica does not, so the set it computes is infinite here (EVERY op-number
   above this replica's own log is provably absent). It cannot be shipped as an explicit list, and
   it does not need to be: under the spec's own [StorageWellFormed] (VSR.tla:742-745) and
   [LogLengthMatchesOpNumber] (:728-729) -- both exhaustively TLC-checked -- [CanNack(r, o)] holds
   PRECISELY for [o > rep_op_number[r]], so the sender's own [n] field already carries the whole
   infinite set, exactly. [nack_proves_absent] below is where the receiving side spends it.

   What this function therefore computes is the remainder: an explicitly-proven-absent op-number
   at or below the sender's own op-number. Under the current storage layer that set is EMPTY BY
   CONSTRUCTION -- provably, for every reachable state, and not as a coverage gap: a slot within
   the durable range reads back [Present] or [Corrupt], NEVER [Absent]. That is [slot_state]'s own
   construction (:451-463), and it is the property the whole nack-soundness argument rests on. So
   this function returns [[]] today, always. It is written as a real scan rather than hard-coded
   to [[]] so the structural reason stays legible next to the code that depends on it.

   NOTE, because [slot_state]'s own type-declaration comment now leans on this (review finding M4):
   the emptiness does NOT depend on which op-number reading [slot_state] uses. The horizon below is
   [max t.op_number (wal_highest_op_number ())], which is exactly [slot_state]'s [Absent] threshold
   under the STRICT reading; under the durable reading that threshold can only be HIGHER, so the
   scanned range stays entirely below it either way and the set stays empty. Whatever else changing
   that reading would do, it cannot move this function's result.

   DO NOT read that as "a drop-in extension point the receiver already supports". It is not. The
   receiving side REJECTS in-range nack evidence: [nacks_wellformed] (:1405) drops any DVC
   carrying a nack at or below the sender's own [n] WHOLESALE -- the entire message is discarded
   as malformed, not partially honoured, not specially handled (pinned by
   [test_out_of_range_nack_is_a_total_no_op] in test_vsr_replica_recovery.ml and by a
   field-validation case in test_vsr_replica.ml). That rejection is correct and load-bearing, not
   merely tolerated: it is the right strengthening under [StorageWellFormed] (VSR.tla:742-745),
   and it is what keeps [sender_proves_absent] monotone in [op_number], which is in turn what
   makes [completion_point]'s downward-scan bound exact rather than heuristic (an ACCEPTED nack
   must satisfy [o > n], so it is fully subsumed by that disjunct and adds nothing).

   Consequently, if a future storage layer or partial-repair path ever needs to report a genuine
   in-range hole, it must RELAX [nacks_wellformed] in the same change that widens this function.
   Widening the sender alone would make every DoViewChange from such a replica malformed to every
   peer, permanently wedging every view change that replica takes part in. *)
let provable_nacks t =
  let horizon = max t.op_number (t.storage.wal_highest_op_number ()) in
  let rec loop o acc =
    if o < 1 then acc
    else loop (o - 1) (match slot_state t ~op_number:o with Absent -> o :: acc | Present _ | Corrupt -> acc)
  in
  loop horizon []

(* THE REVIEW-FOCUS GUARD (this plan's own Review Focus list, Task 7): "VSR's own safety guarantee
   is that committed entries never disappear -- this must be rejected by the caller (replica.ml),
   not silently accepted by the storage primitive".

   [~resulting_length] is what makes this guard say what it means rather than something narrower.
   The property to protect is the NET effect on durable state: no committed entry may be gone once
   the operation this truncate is part of has finished. Two callers, two different values:

   - A pure discard (the only one that exists today is {!for_test_truncate_wal}) passes
     [~resulting_length:op_number] -- nothing is written back afterwards, so the guard reduces
     to exactly "op_number >= commit_number".
   - A log ADOPTION ([adopt_log] below, i.e. [SendSV]/[ReceiveSV]) truncates to the longest
     already-correct prefix and then re-appends the rest of the canonical log in the same step, so
     the durable log ends at the canonical length. Checking that length is what lets a corrupt
     slot BELOW the commit point be repaired -- rewriting op 2 when commit_number is 3 requires
     truncating to 1 first, and a guard stated on the truncate's own argument would reject exactly
     the repair the recovery protocol exists to perform, while permitting nothing safer.

   [~committed] is likewise the commit-number IN EFFECT for the operation, not necessarily
   [t.commit_number] at entry: [SendSV] establishes a new commit-number from the DVC quorum in the
   same step it installs the new log (VSR.tla:506-509), and [ValidCompletion]'s own
   [L >= HighestCommitNumber(r)] clause (VSR.tla:460) is the spec's statement of this very guard
   against that new value. *)
let truncate_wal t ~op_number ~committed ~resulting_length =
  if resulting_length < committed then invalid_arg "recovery: refusing to truncate below commit_number";
  t.storage.wal_truncate_after ~op_number

(* A durable append that reports refusal instead of raising. A backend may legitimately reject an
   entry ({!Riptide_storage.File_storage} raises [Invalid_argument] for anything larger than one
   aligned data slot), and a rejected write means the entry is NOT durable -- so the replica must
   not go on to acknowledge it. VSR.tla:243-245's own note is that appending and replying
   PREPAREOK are one step precisely because the entry is durable before it is acknowledged; this
   is that coupling, made real. Returning [false] keeps [handle_message] total on adversarial
   input (an oversized value on the wire must drop the message, never escape as an exception).

   I2 / TASK 12: WHICH refusal is now classified and counted rather than flattened -- see
   [append_refusal]'s own comment above for the five shapes (three from I2, [Eviction_blocked]
   added by subtask 3.7, [Storage_fault] added by Task 12), the measurement behind the first three,
   and why an [Invalid_argument] matching none of the first four, or a real I/O exception matching
   neither [Storage_fault]'s four narrow errnos nor [Out_of_memory], PROPAGATES instead. That
   propagation does not weaken the totality guarantee above: every refusal a real backend in this
   repo raises for a real entry is one of the five classified shapes (each pinned by a test -- see
   test_vsr_replica_recovery.ml's refusal-classification section, which covers all five, including
   [Storage_fault]'s own narrow classification and its propagating counter-cases), so what escapes
   here is a backend contract violation, which is precisely the thing that must not be laundered
   into "the protocol declined an op".

   Subtask 3.7's [Eviction_blocked] is worth one extra note HERE, at the call site, because it is
   the first refusal a well-formed append can hit: returning [false] for it means this replica
   declines to acknowledge an op it could otherwise have taken on, deliberately trading liveness for
   the durability of an older entry its owner has not finished with. [propose] and [handle_prepare]
   already treat a classified refusal as a silent no-op, and for THEM that is accurate: nothing has
   happened yet, so the trade needs no new code there. [adopt_durable_log] (reached via
   [try_send_sv]/[handle_start_view]) is a third real caller, through its own [append_rest] loop,
   and is NOT the same shape: by the time that loop reaches this call, [truncate_wal] has already
   zeroed every discarded slot, so a refusal here does not land on a clean no-op -- it leaves the
   durable log partially rewritten (only [prefix_ok] plus however much of the canonical suffix did
   get re-appended before the refusal) until a subsequent successful re-append or another StartView
   completes the adoption. That degradation is still safe, by the same argument [Out_of_sequence]
   above already relies on: the un-rewritten gap reads back [Corrupt], never [Absent] (see
   [slot_state]), and no exception escapes -- but it is "log adoption left incomplete", not
   "nothing happened", and any [?may_evict] predicate a future consumer (Task 6) supplies must stay
   permissive enough that adoption/repair traffic through [adopt_durable_log] is never itself
   starved by the same eviction gate meant for ordinary [propose]/[handle_prepare] appends. It is
   also the reason [append_refusals] was promoted out of test-only visibility: a refusal that is
   CORRECT and INDEFINITE is one an operator has to be able to see.

   [Value.canonical_encode] is evaluated OUTSIDE the handler on purpose: it has its own
   [Invalid_argument] failure modes, and catching those here would put an encoding bug in the
   value layer into a storage-refusal bucket -- the same conflation at one remove.

   TASK 12 (Decision 3.3): the [Storage_fault] arm below sits AFTER the [Invalid_argument]
   classification, deliberately -- it catches only what that classification structurally cannot
   (none of its patterns are [Invalid_argument]), and only a NARROW slice even of that: [Out_of_memory]
   itself, and an [Eio.Io]/bare [Unix.Unix_error] wrapping exactly [ENOSPC], [EDQUOT]
   ([EUNKNOWNERR 122] -- see [append_refusal]'s own comment above for why), [EIO], or [ENOMEM].
   Everything else -- a bare [Sys_error], any other errno, any [Eio.Io] wrapping a classified
   {!Eio.Fs.error} -- propagates, exactly like an unrecognized [Invalid_argument] does. Ordering the
   two arms this way keeps every existing [Invalid_argument] shape -- including the propagating
   [None] case above, which must stay an [Invalid_argument] escape, not get laundered into
   [Storage_fault] -- completely unaffected by this addition.

   WAL-LEVEL CAVEAT (Storage-Important-1 follow-up, not a new problem this task introduces): unlike
   the four [Invalid_argument] refusals above, a [Storage_fault] raised mid-{!Riptide_storage.File_storage.wal_append}
   is not always a clean no-op at the DURABLE-STORAGE level, even though it is always a clean no-op
   at THIS replica's in-memory level (nothing above this line mutates before the call, and [false]
   is returned without touching anything else). See [append_refusal]'s own comment above for the
   full disclosure of what a failure between [wal_append]'s two non-atomic writes can leave behind
   in the ring. *)
let durable_append t ~op_number (v : Value.value) =
  let bytes = Value.canonical_encode v in
  match t.storage.wal_append ~op_number bytes with
  | () -> true
  | exception Invalid_argument msg -> (
    match classify_append_refusal msg with
    | Some refusal ->
      let i = append_refusal_index refusal in
      t.append_refusals.(i) <- t.append_refusals.(i) + 1;
      false
    | None -> invalid_arg msg)
  | exception
      ( Out_of_memory
      | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (Unix.(ENOSPC | EIO | ENOMEM | EUNKNOWNERR 122), _, _)), _)
      | Unix.Unix_error (Unix.(ENOSPC | EIO | ENOMEM | EUNKNOWNERR 122), _, _) ) ->
    let i = append_refusal_index Storage_fault in
    t.append_refusals.(i) <- t.append_refusals.(i) + 1;
    false

(* The durable half of [SendSV]/[ReceiveSV]'s wholesale log replacement, and of VSR.tla's
   [rep_storage' = FreshStorage(L)] (VSR.tla:509, :573): after this returns [true], op-numbers
   [1..Len(values)] are durably present and verified, and everything above is gone.

   Written as "keep the longest already-correct prefix, truncate, re-append the rest" rather than
   "rewrite everything", because the prefix is the common case by far (a view change usually keeps
   the whole log) and because {!Riptide_storage.Storage_intf.S} has no random-access write at all:
   [wal_append] only ever extends by exactly one.

   CRASH ORDERING, stated because it is load-bearing rather than incidental: the WAL is rewritten
   FIRST and the superblock is updated by the caller afterwards. A crash in between therefore
   leaves a superblock whose [op_number] is at least the durable log's real length, which is the
   conservative direction -- the not-yet-rewritten slots read back as CORRUPT (in range, not
   returnable), never as ABSENT, so a replica interrupted mid-adoption cannot nack an op it might
   still have been holding. *)
let adopt_durable_log t (values : Value.value list) ~committed =
  let target_length = List.length values in
  let prefix_ok =
    let rec loop o = function
      | [] -> o - 1
      | v :: rest ->
        (* [value_equal], never OCaml's structural [=]: canonical-encoding identity is this
           codebase's value identity (see [value_equal]'s own comment). *)
        (match slot_state t ~op_number:o with
        | Present stored when value_equal stored v -> loop (o + 1) rest
        | Present _ | Corrupt | Absent -> o - 1)
    in
    loop 1 values
  in
  truncate_wal t ~op_number:prefix_ok ~committed ~resulting_length:target_length;
  let rec append_rest o = function
    | [] -> true
    | v :: rest -> if o <= prefix_ok then append_rest (o + 1) rest else durable_append t ~op_number:o v && append_rest (o + 1) rest
  in
  append_rest 1 values

(* ---- CrashRestart (VSR.tla:671-690) ----
   The real-code counterpart of the spec's single fused storage-fault-discovery-and-restart
   action: build a fresh [t] over storage that already holds durable state. Constructing the
   replica IS the restart -- everything volatile is at its [Init] value by construction (see
   [make]), and nothing from the previous [t] can leak in, because there is no previous [t] in
   scope.

   DURABLE (survives, VSR.tla:592-596): log, op_number, commit_number, view_number,
   last_normal_view -- the first from the WAL, the rest from the superblock.
   VOLATILE (lost, VSR.tla:599-601): peer_op_number, recv_svc, recv_dvc, sent_dvc.
   STATUS is RECONSTRUCTED from [view_number > last_normal_view] (VSR.tla:680-682), never stored.

   Two real-storage reconciliations the abstract model does not need, both conservative:

   1. The WAL may hold entries the superblock does not know about (a crash between [wal_append]
      and [persist_superblock]). Those were never acknowledged -- the PREPAREOK that would have
      exposed them is sent only after both writes -- so they are discarded here, which also
      restores the [wal_highest_op_number = op_number] agreement every later [wal_append] depends
      on. The truncate goes through the same guarded path as every other: dropping unacknowledged
      entries can never drop a committed one, and [truncate_wal] is what checks that rather than
      this comment.
   2. The in-memory log is rebuilt only as far as the first unreadable slot, while [op_number]
      keeps its full durable value. That gap is exactly VSR.tla's "corrupt" state, and it is why
      [op_number] is a field rather than [Replica_log.length]: the replica still knows what it
      owes ([n] on its DoViewChange), it just cannot read all of it. Until a StartView repairs it,
      such a replica declines new Prepares (see [handle_prepare]) -- state transfer is out of
      scope for this spec, disclosed in spec/tla/README.md.

   FAIL-STOP, NOT FAIL-SILENT, WHEN THE SUPERBLOCK IS UNUSABLE OVER A NON-EMPTY WAL (final-review
   finding C1). This is the one place [restart] refuses to construct a replica at all, and the
   reasoning is the whole nack-soundness argument, so it is stated here in full rather than left
   to the guard's own message:

   An unusable superblock is not rare and needs no injected fault. [superblock_write] is 3
   SEQUENTIAL, NON-ATOMIC copy writes (each itself a header write then a data write), and
   [superblock_read] returns [None] -- correctly, by its own flexible-quorum design -- whenever
   fewer than 2 of those 3 copies verify and agree. An ordinary crash partway through that
   sequence lands exactly there, with the WAL completely untouched and fully readable.

   The previous behaviour was to fall back to [(0, 0, 0, 0)] and then truncate the WAL down to
   match [op_number = 0]. That is not a conservative default; it is the single most dangerous
   state this protocol has. [sender_proves_absent] (:1091) treats EVERY op above a sender's own
   [n] as PROVABLY ABSENT -- that disjunct is sound only because [StorageWellFormed]
   (VSR.tla:742-745) guarantees a durably-written slot can never read back absent. A replica that
   comes back claiming [n = 0] over a WAL that still holds its entries breaks precisely that
   guarantee: it proves absent every op it ever durably held. Combined with one honest nack from a
   replica that genuinely never saw the op, that is a nack quorum, and [completion_point]
   truncates a committed, client-acknowledged value cluster-wide.

   spec/tla/VSR.tla:111-150 records TLC refuting exactly this mutation -- one word, "corrupt" to
   "absent", violating [NoCommittedOpProvablyAbsent] at depth 6. The fallback WAS that mutation,
   in OCaml. So [restart] refuses instead: [Invalid_argument], matching [create]'s own convention
   for its own precondition violations (a constructor whose preconditions do not hold does not
   return a half-usable value), and leaving every byte of durable state untouched so whatever
   rebuilds the superblock still has the log to rebuild it from. A loud refusal to start one
   replica is recoverable by operator action; silent cluster-wide loss of committed data is not.
   It is the same failure shape this branch already accepts, deliberately, for the pinned
   ring-capacity finding: stop rather than destroy.

   TASK 13 (audit-remediation): "whatever rebuilds the superblock" above used to name no actual
   entry point -- this guard could detect the state and refuse, but nothing existed to repair it,
   so a replica caught here stayed down permanently even though its WAL had everything needed to
   recover. {!Riptide_storage.Storage_intf.S.superblock_rebuild_from_wal} (concretely,
   {!Riptide_storage.File_storage.superblock_rebuild_from_wal} for a real deployment) is that
   entry point now: call it on the same backend, then retry this constructor. The message below
   names it by name for exactly this reason -- an operator hitting this state in a log should not
   have to go spelunking through this comment to learn what to run.

   TASK 13 FIX ROUND (review finding 1): that repair is NOT, and cannot be, an automatic self-heal,
   and the message below says so rather than reading like "just run this function". Its first cut
   took no arguments and silently wrote [view_number = last_normal_view = commit_number = 0], on the
   reasoning that under-claiming costs only liveness. That reasoning is wrong, and the counterexample
   is a concrete three-replica trace now pinned by a running test (see
   [test/test_vsr_replica_recovery.ml]'s
   [test_a_rebuild_with_zeroed_values_destroys_a_committed_op_through_a_view_change],
   [test_a_rebuild_with_only_last_normal_view_wrong_still_destroys_it] and
   [test_a_rebuild_with_correct_values_preserves_that_same_committed_op]): a replica rebuilt with
   [last_normal_view = 0] loses
   [WinningDVC]'s log selection (:1300, highest [last_normal_view] wins) to a peer that honestly
   reports a HIGHER one over a SHORTER log, and the new view's log is then reconstructed without the
   committed op -- cluster-wide, silently. Under-claiming is not automatically the conservative
   direction; it is only conservative for a value NOBODY ELSE compares against, and
   [last_normal_view] is precisely a value other replicas rank this one by. So the three
   non-WAL-derivable fields are the caller's to supply, and this guard's message says exactly that.

   TASK 13 RE-REVIEW (finding 1): that fix round's OWN advice about WHERE the caller gets them --
   "from a live surviving peer", which both this comment and the message below used to say in those
   words -- is RETRACTED, because it is catastrophic in the opposite direction. A peer's CURRENT
   [last_normal_view] exceeds this replica's true one whenever this replica had fallen behind it on
   view transitions, and an OVER-claimed [last_normal_view] makes this replica WIN [WinningDVC]'s
   selection (tie on [last_normal_view], then longest log) with a STALE log, so [FillValue] rebuilds
   already-committed op-numbers from this replica's superseded values while [HighestCommitNumber]
   independently carries the real commit-number forward -- the cluster silently adopts DIFFERENT
   values for operations clients were already told had succeeded. Pinned by
   [test_a_rebuild_copying_a_live_peers_current_values_replaces_committed_data] and its fixed
   counterpart. There is no known safe GENERAL procedure for sourcing these values externally; the
   only safe triple is this replica's OWN true prior state.

   AND ROUND 3 (finding 1) RETRACTED THE ONE EXAMPLE OF SUCH A SOURCE THIS COMMENT USED TO OFFER: an
   external monitor of this replica's own traffic does NOT qualify, because DURABILITY PRECEDES
   OBSERVABILITY at every site in this file that moves any of the three fields -- [check_timeout],
   [handle_start_view_change]'s higher-view branch, [try_forfeit_view_change] and [try_send_sv] all
   [persist_superblock] and only THEN send, and [handle_start_view] raises
   [view_number]/[last_normal_view] and sends nothing at all. An observed triple is therefore at best
   a lower bound and at worst wrong in either direction. The only source that qualifies is one
   SYNCHRONOUSLY COUPLED to the durable write (a mirrored copy of the RECORD, not of the messages);
   none exists here, so the honest status is that this repair has no practical safe-sourcing
   mechanism at all today. See
   {!Riptide_storage.Storage_intf.S.superblock_rebuild_from_wal}'s own doc comment for both traces,
   for that disclosed limitation, and for why a real VSR Recovery sub-protocol -- the classical
   mechanism for this situation -- is deliberately out of scope here.

   THE GUARD'S OWN CONDITION reads [wal_highest_durable_op_number], not [wal_highest_op_number]
   (Task 13 re-review finding 2, which found a previous comment in [file_storage.ml] falsely
   claiming this path could not under-report). The strict reading returns 0 for a backend whose every
   header-verifying slot has unreadable DATA, so this guard would stay silent and the replica would
   come up as a fresh, empty one over durable evidence of ops it really did accept -- the same
   prove-absent hazard, reached through this guard's own blind spot rather than through the
   zero-fallback it replaced.

   The guard is conditioned on the WAL, not on the superblock alone, and that is load-bearing:
   an empty backend (no superblock AND no WAL) is FIRST BOOT, not a lost superblock, and must
   still yield exactly [create]'s [Init] state -- otherwise [restart] stops being usable as a
   general entry point at all. *)
let restart ?on_commit_advanced ~my_id ~replica_count ~svc_limit ~send ~storage () =
  validate_create_args ~fn:"Replica.restart" ~my_id ~replica_count ~svc_limit;
  let durable = Option.bind (storage.superblock_read ()) superblock_decode in
  if durable = None && storage.wal_highest_durable_op_number () > 0 then
    invalid_arg
      "Replica.restart: this backend's superblock is unreadable while its WAL is NOT empty -- \
       refusing to start. Coming up with op_number = 0 over a WAL that still holds entries would \
       make this replica prove absent (VSR.tla's CanNack) every op it durably held, which a nack \
       quorum turns into cluster-wide loss of committed data (VSR.tla:111-150). The durable log is \
       intact and untouched; recovering this replica needs either the superblock rebuilt or the \
       backend discarded wholesale, neither of which restart can decide on its own. TO REBUILD \
       (Task 13): call this backend's own Storage_intf.S.superblock_rebuild_from_wal ~view_number \
       ~last_normal_view ~commit_number (e.g. \
       Riptide_storage.File_storage.superblock_rebuild_from_wal), then retry Replica.restart. THOSE \
       THREE VALUES ARE REQUIRED AND MUST NOT BE GUESSED, AND THE ONLY SAFE VALUES ARE THIS \
       REPLICA'S OWN TRUE PRIOR DURABLE STATE -- the exact triple its own superblock held before \
       the write that tore it. DO NOT COPY THEM OFF A LIVE PEER'S CURRENT STATE: an earlier version \
       of this message told you to do exactly that, and that advice is WITHDRAWN as actively wrong. \
       A value too LOW makes this replica lose view-change log selection to a peer holding a SHORTER \
       log, silently destroying a committed op cluster-wide -- the exact loss this refusal exists to \
       prevent, reintroduced by the repair. A value too HIGH -- which is what a surviving peer's \
       CURRENT last_normal_view gives you whenever this replica had fallen behind that peer on view \
       transitions, something nobody can rule out once THIS replica's own superblock is gone -- \
       makes this replica WIN that selection with a stale log and silently REPLACE the cluster's \
       real, already-acknowledged committed values with its own. THE ONLY SOURCE THAT QUALIFIES is \
       one SYNCHRONOUSLY COUPLED to this replica's own durable superblock write -- a copy of the \
       RECORD that became durable with it, not a record of the messages this replica sent. An \
       external monitor watching this replica's traffic does NOT qualify, and an earlier version of \
       this message wrongly offered it as an example: every durable write here happens strictly \
       BEFORE the message that announces it, and a backup adopting a new view (ReceiveSV) announces \
       nothing at all, so an observed triple can be wrong in EITHER catastrophic direction. As of \
       Task 13 no such synchronously-coupled source exists in this codebase, so in practice this \
       repair CANNOT be used safely and the backend must be discarded wholesale instead. See \
       Storage_intf.S.superblock_rebuild_from_wal's own doc comment for both traces and for the full \
       disclosed limitation.";
  let view_number, last_normal_view, op_number, commit_number =
    match durable with
    | Some (v, lnv, n, k) -> (v, lnv, n, k)
    (* Reachable ONLY for a genuinely empty backend now -- the guard above has already refused
       every other route here. This is [create]'s own [Init] (VSR.tla:79), i.e. first boot. *)
    | None -> (0, 0, 0, 0)
  in
  let t =
    make ~my_id ~replica_count ~svc_limit ~send ~storage ~view_number ~last_normal_view ~op_number
      ~commit_number
      ~status:(if view_number > last_normal_view then View_change else Normal)
      ~on_commit_advanced
  in
  (* Also the DURABLE reading (Task 13 re-review finding 2), so this condition cannot read FALSE for
     a backend that is in fact still holding something above the superblock's own [op_number].

     WHAT THE CONDITION ACTUALLY DOES, stated accurately -- review finding M3. The previous version of
     this comment claimed "a slot whose header survived the crash above the superblock's own
     [op_number] is physically discarded here", and that is NOT what happens:

     - When the entries above [op_number] are FULLY readable -- the ordinary case, a crash between
       [durable_append] and [persist_superblock] -- BOTH readings exceed [op_number], the truncate
       fires for real, and those entries are physically discarded. That is the case this guard exists
       for, and [test_restart_discards_wal_entries_the_superblock_never_saw] pins it.
     - When only a HEADER survived above [op_number] (exactly the case the durable reading was
       introduced for), the two readings differ and this condition is what makes the call happen at
       all -- but the call is then a NO-OP:
       {!Riptide_storage.File_storage.wal_truncate_after}, the only backend that can BE in this state
       (Memory_storage's two readings coincide by construction, and Fault_injecting_storage
       delegates), gates its body on the STRICT [op_number < highest_op_number], which is false here.
       Nothing is discarded; the header-only slot stays where it is. Pinned by
       [test_a_header_only_slot_above_the_superblock_is_not_discarded_and_is_never_nacked] in
       test_vsr_replica_recovery.ml, so this correction cannot silently stop matching the code.

     WHY THAT LEFTOVER SLOT IS HARMLESS, which is why this is a comment correction rather than a code
     change. It reads back [Absent] through [slot_state], whose horizon is
     [max t.op_number (wal_highest_op_number ())] -- exactly [op_number] here -- and proving it absent
     is precisely what [CanNack] (VSR.tla:157) licenses: it was never acknowledged, because the
     PREPAREOK that would have exposed it is sent only after BOTH the WAL and the superblock write.
     The only other trace it leaves is a permanently inflated
     {!Riptide_storage.Storage_intf.S.wal_highest_durable_op_number}, and that is the conservative
     direction for both guards that read it (more likely to fail-stop, more likely to refuse a backend
     as non-virgin -- never less).

     The durable reading is still the right one HERE, for a forward-looking reason rather than the
     retracted one: a backend whose [wal_truncate_after] did physically discard header-only slots would
     make this call do real work, and the condition would have to be true for it to be reached at all.
     [truncate_wal]'s own [~committed] guard, not this comment, is what checks that nothing committed is
     discarded on the occasions the call does fire. *)
  if storage.wal_highest_durable_op_number () > op_number then
    truncate_wal t ~op_number ~committed:commit_number ~resulting_length:op_number;
  let rec readable_prefix o acc =
    if o > op_number then List.rev acc
    else match slot_state t ~op_number:o with Present v -> readable_prefix (o + 1) (v :: acc) | Corrupt | Absent -> List.rev acc
  in
  Replica_log.replace_with t.log (readable_prefix 1 []);
  t

let is_committed t v =
  let rec loop n =
    if n > t.commit_number then false
    else
      match Replica_log.get t.log ~op_number:n with
      | Some x when value_equal x v -> true
      | _ -> loop (n + 1)
  in
  loop 1

(* ---- IsCommitted / PrimaryExecuteOp (VSR.tla:138-155) ----
   Defined ahead of [propose]/[handle_prepare_ok] because BOTH drive it: see the doc comment on
   [primary_execute_op] below, and replica.mli's own note on why [propose] must also call it
   (VSR.tla's [PrimaryExecuteOp] guard has two conjuncts, and [ReceiveClientRequest] -- i.e.
   [propose] -- is the action that changes the FIRST one, [rep_commit_number[r] <
   rep_op_number[r]], not just [ReceivePrepareOkMsg]). *)

let is_committed_quorum t ~op_number =
  let f = (t.replica_count - 1) / 2 in
  (* [peer <> t.my_id] is VSR.tla's own [\ {r}] exclusion. The [p \in replicas] range check that
     VSR.tla:141's set comprehension also requires is enforced once, at insertion, by
     [handle_prepare_ok]'s own range check (see [peer_op_number]'s own doc comment above) -- every
     key already in this table is guaranteed in [1, replica_count], so no second check is needed
     here. *)
  let acked_backups =
    Hashtbl.fold
      (fun peer acked_n acc -> if peer <> t.my_id && acked_n >= op_number then acc + 1 else acc)
      t.peer_op_number 0
  in
  acked_backups >= f

(* Advances commit_number strictly one step at a time, from commit_number+1 upward, stopping at
   the first not-yet-committed op-number (or once commit_number = op_number t). Deliberately
   never jumps directly to the triggering Prepare_ok's own [n] -- see replica.mli's own doc
   comment on handle_message for exactly why that would be wrong.

   Called from BOTH [propose] and [handle_prepare_ok]: [PrimaryExecuteOp]'s guard
   (VSR.tla:145-150) is a conjunction of [rep_commit_number[r] < rep_op_number[r]] (changed by
   [ReceiveClientRequest], i.e. [propose]) and [IsCommitted(r, next)] (changed by
   [ReceivePrepareOkMsg], i.e. [handle_prepare_ok]) -- either action can newly enable it, so both
   must drive it. For [replica_count >= 3] (so [f >= 1]) calling it from [propose] is a provable
   no-op, since a fresh op with zero acks never satisfies [IsCommitted]; it only has a visible
   effect in the degenerate [f = 0] case ([replica_count = 1]), where [IsCommitted] is vacuously
   true for every op-number and the primary can commit its own proposal with no acks at all,
   matching what VSR.tla's own [Next] would allow (nothing stops [PrimaryExecuteOp] from firing
   immediately after [ReceiveClientRequest] in that case). *)
let primary_execute_op t =
  let continue_ = ref true in
  let advanced = ref false in
  while !continue_ do
    if t.commit_number >= op_number t then continue_ := false
    else begin
      let next = t.commit_number + 1 in
      (* Storage-fault-aware addition to the normal path (VSR.tla:282-291): the primary must be
         able to READ the entry it is about to execute ([Holds(r, next)]). Counting itself toward
         the f+1 while its own copy is unreadable would let a cluster commit with only f readable
         copies. *)
      let readable = match slot_state t ~op_number:next with Present _ -> true | Corrupt | Absent -> false in
      if readable && is_committed_quorum t ~op_number:next then begin
        advance_commit_number t next;
        advanced := true
      end
      else continue_ := false
    end
  done;
  if !advanced then persist_superblock t

(* ---- ReceiveClientRequest (VSR.tla:91-102) ---- *)

let propose t (v : Value.value) =
  if t.status <> Normal then () (* IsNormalPrimary(r) guard: not enabled outside status="Normal" *)
  else if not (is_primary t) then () (* IsNormalPrimary(r) guard's other conjunct: r = Primary(View(r)) *)
  else if List.exists (fun existing -> value_equal existing v) (entries t) then ()
  else if Replica_log.length t.log <> t.op_number then
    () (* This replica has an unreadable slot below its own op-number (only reachable via
          [restart]), so its in-memory log is a strict prefix of what it durably owes. Minting a
          NEW op-number on top of that would require appending at [op_number + 1] over a gap --
          [Replica_log.append]'s own out-of-order guard would raise, and the durable and in-memory
          copies would disagree about what op [n] holds. Declining until a StartView repairs the
          hole is the same "guard failure => total no-op" discipline used throughout this module,
          and costs liveness only: a primary in this state cannot serve clients, which is exactly
          the condition a view change exists to resolve. *)
  else begin
    let n = t.op_number + 1 in
    (* DURABLE FIRST, then in-memory, then the broadcast. VSR.tla:243-245: the entry is durable
       before it is acknowledged, so a backend that refuses the write must stop the whole action
       rather than leave the in-memory log ahead of the WAL. *)
    if durable_append t ~op_number:n v then begin
      Replica_log.append t.log ~op_number:n v;
      t.op_number <- n;
      persist_superblock t;
      let bytes =
        Message.encode (Message.Prepare { view = t.view_number; n; v; k = t.commit_number; source = t.my_id })
      in
      for peer = 1 to t.replica_count do
        if peer <> t.my_id then t.send ~to_:peer bytes
      done;
      primary_execute_op t (* see primary_execute_op's own doc comment for why this call is needed *)
    end
  end

(* ---- ReceivePrepareMsg (VSR.tla:104-123) ---- *)

let handle_prepare t ~view ~n ~(v : Value.value) ~k ~source =
  if t.status <> Normal then () (* IsNormalBackup(r) guard: not enabled outside status="Normal" *)
  else if is_primary t then () (* IsNormalBackup(r) guard's other conjunct: not enabled for the primary itself *)
  else if view <> t.view_number then ()
  else if source <> primary t then
    () (* Finding 3 of the audit-remediation Task 3 fix round: [handle_message]'s own cross-check
          (below) only proves [source] IS who transport-authenticated [sender] really is -- it says
          nothing about whether that real, credentialed replica had any business sending a
          [Prepare] at all. A [Prepare] is only ever legitimate from THIS view's primary
          (VSR.tla's own [IsNormalBackup(r)] conjunct on the SENDING side, mirrored by
          [primary_execute_op]/[propose] only ever being reachable for [is_primary t]), so any
          other credentialed replica sending one -- under its own true identity, no spoofing
          required -- must be rejected exactly the way a wrong-view or out-of-order one already
          is. [primary t], not [primary_of_view ~replica_count:t.replica_count view], is the right
          comparison here specifically BECAUSE the guard just above already forces [view =
          t.view_number]: a [Prepare] for any other view never reaches this line, so there is no
          "the message's own view differs from mine" case for this handler the way there is for
          [handle_start_view] below. *)
  else if n <> t.op_number + 1 then
    () (* VSR.tla:251's own [rep_op_number[r] + 1 = m.n]: backups process PREPARE strictly in
          op-number order. Checked against the DURABLE op-number here (and re-checked structurally
          by [Replica_log.append] below) -- after a restart that found a hole, the two disagree,
          and it is the durable one the rest of the cluster is talking about. *)
  else if Replica_log.length t.log <> t.op_number then
    () (* Unrepaired hole below our own op-number -- see [propose]'s identical guard for why this
          replica must decline until a StartView repairs it, rather than append over the gap. *)
  else if not (durable_append t ~op_number:n v) then
    () (* The backend refused the write, so the entry is NOT durable and must NOT be acknowledged
          (VSR.tla:243-245). Total no-op, exactly like any other guard failure here. *)
  else
    match Replica_log.append t.log ~op_number:n v with
    | exception Replica_log.Out_of_order_append _ ->
      () (* out-of-order: action not enabled, per VSR.tla -- silently drop, no reply, no state change *)
    | () ->
      t.op_number <- n;
      (* VSR.tla:236-241's own comment argues the unguarded [m.k > @] update (VSR.tla:255) is safe
         because a well-formed [Prepare] always has [m.k < m.n] (VSR.tla:239 -- prose only; it is
         NOT a conjunct of [ReceivePrepareMsg], whose real guards are VSR.tla:248-251) -- a
         property only true of
         messages produced by the spec's OWN actions, which a decoded, possibly network-corrupted
         message is not guaranteed to have. [k <= op_number t] (== [m.n], just appended above)
         bounds [k] explicitly instead of trusting that precondition, so a corrupted/forged [k]
         can never push commit_number past what this replica's own log actually contains --
         preserving [CommitNumberNeverHigherThanOpNumber] (VSR.tla:330-331) for every input, not
         just well-formed ones. A genuinely higher, in-range [k] from a well-formed message is
         still applied exactly as before.

         SETTLED (this was the FORWARD NOTE an earlier task left here, and this task is the moment
         it predicted): the bound is now [k < op_number t], exactly VSR.tla:106-109's own
         [m.k < m.n] precondition, no longer one step wider. It used to admit [k = n] as a
         deliberate defense-in-depth margin, justified solely by [k = n] being harmless while a
         backup's commit_number was purely local state -- at [k = n] the entry at [n] exists and
         [commit_number = op_number], so [CommitNumberNeverHigherThanOpNumber] and
         [NoLogDivergence] both still held. That justification is now GONE: this task wires
         [try_send_dvc] (already merged) into [ReceiveDVC]/[HighestCommitNumber]/[SendSV] below, so
         a backup's commit_number leaves the replica as [DoViewChange.k] and feeds
         [HighestCommitNumber] (VSR.tla:257-260) -- an INDEPENDENT maximum over all valid DVCs' [k]
         fields, NOT derived from the winning DVC. A backup whose commit_number was inflated by one
         by a corrupted [Prepare] therefore becomes the new primary's own commit_number and is
         broadcast cluster-wide as [StartView.k], where it can exceed the winning log's own length.
         The margin is no longer benign, so it is gone: [k = n] is now REJECTED (only the [k]
         field's effect is dropped -- the Prepare itself is still appended and still acked, exactly
         as for the out-of-bound case this bound has always rejected). test_vsr_replica.ml's own
         k-boundary tests pin all three of [k = n-1] (well-formed, accepted), [k = n] (now
         rejected) and [k = n+1] (rejected). *)
      if k > t.commit_number && k < op_number t then advance_commit_number t k;
      (* One superblock write covers BOTH durable changes this action makes (the new op_number and
         any commit_number advance), and it happens BEFORE the PREPAREOK goes out: the reply is
         this replica's promise that the entry is durable, so every durable field the entry's
         acknowledgement implies must already be on disk when it is sent. *)
      persist_superblock t;
      let reply = Message.encode (Message.Prepare_ok { view = t.view_number; n; i = t.my_id }) in
      t.send ~to_:(primary t) reply

(* ---- ReceivePrepareOkMsg (VSR.tla:125-136) ---- *)

let handle_prepare_ok t ~view ~n ~i =
  if t.status <> Normal then () (* IsNormalPrimary(r) guard: not enabled outside status="Normal" *)
  else if not (is_primary t) then ()
  else if view <> t.view_number then ()
  else if i < 1 || i > t.replica_count then
    () (* VSR.tla:141's own [p \in replicas] domain restriction -- a decoded [i] naming no real
          replica must never be allowed into [peer_op_number] at all (see that field's own doc
          comment above for why this is the single point where the invariant is established) *)
  else if n > op_number t then
    () (* A genuine [Prepare_ok] can never legitimately claim to have acked an op-number higher
          than what THIS primary has itself assigned via a Prepare broadcast -- op-numbers are
          minted only by this replica's own log (op_number t = Replica_log.length), so [m.n]
          can be at most that. Left unbounded, a forged (or corrupted) [n] from an otherwise
          real replica id permanently pre-acks every future op this primary ever proposes,
          letting it "commit" with zero real acks once op_number catches up -- the same
          AcknowledgedWritesExistOnMajority violation M1/M2 were fixed against, just via [n]
          instead of [i]/[k]. *)
  else begin
    let prev = Option.value (Hashtbl.find_opt t.peer_op_number i) ~default:0 in
    if n > prev then Hashtbl.replace t.peer_op_number i n;
    primary_execute_op t
  end

(* ---- SendDVC (VSR.tla:216-228) ----
   Driven from every point [recv_svc] actually changes -- [check_timeout]'s own reset to empty,
   and [handle_start_view_change]'s two branches (seed / union) below -- mirroring the normal-case
   plan's [PrimaryExecuteOp]-driven-from-both-[propose]-and-[handle_prepare_ok] pattern exactly: a
   guard with several conjuncts (here [status = View_change], [not sent_dvc], and
   [Cardinality(recv_svc) >= f]) needs a check after EVERY action that can change any one of them,
   not just some of them -- polling from a single call site would miss the others. [check_timeout]'s
   own call is a genuine no-op in every cluster with [f >= 1] (a fresh, empty [recv_svc] can never
   satisfy [Cardinality(recv_svc) >= f] for a positive [f]) -- it only has a real effect in the
   degenerate [f = 0] (replica_count = 1) cluster, where [Cardinality({}) = 0 >= f = 0] is already
   true the instant [check_timeout] itself flips [status] to [View_change]. Included anyway, for
   the same reason [propose]'s own call to [primary_execute_op] is: leaving out the point that only
   matters in the degenerate case is exactly the kind of asymmetry a future refactor could silently
   depend on being "always a no-op" and get wrong. *)
let try_send_dvc t =
  let f = (t.replica_count - 1) / 2 in
  if t.status = View_change && (not t.sent_dvc) && Int_set.cardinal t.recv_svc >= f then begin
    let bytes =
      Message.encode
        (Message.Do_view_change
           {
             v = t.view_number;
             (* VSR.tla:381-383's own two new fields. [entries] is [ReadableEntries(r)] read back
                through the real backend, NOT [Replica_log.to_list] -- a replica must ship what it
                can actually read off its disk, not what a stale in-memory copy says it once had,
                which is the whole point of the partial-function shape (VSR.tla:166-170). [nacks]
                is the explicitly-proven-absent remainder; see [provable_nacks] for why the rest of
                [CanNack]'s (infinite) set rides on [n] instead. *)
             entries = readable_entries t;
             nacks = provable_nacks t;
             last_normal_view = t.last_normal_view;
             n = op_number t;
             k = t.commit_number;
             i = t.my_id;
           })
    in
    t.send ~to_:(primary t) bytes;
    t.sent_dvc <- true
  end

(* ---- ReceiveHigherSVC (VSR.tla:183-194) / ReceiveMatchingSVC (VSR.tla:196-205) ----
   [handle_message]'s own [Start_view_change] dispatch below decides which of these two (if
   either) is enabled for a given decoded message. *)
let handle_start_view_change t ~(v : int) ~(i : int) =
  if i < 1 || i > t.replica_count || i = t.my_id then
    () (* Defense-in-depth, not itself a VSR.tla guard -- mirrors [handle_prepare_ok]'s own [m.i]
          check (see [peer_op_number]'s doc comment above for the general rationale): VSR.tla:15's
          own [replicas == 1..ReplicaCount] domain restriction means [rep_recv_svc[r]] can never
          legitimately contain an out-of-range id in the abstract model (every [StartViewChange]
          there is broadcast with [i] set to the sending replica's own, always-valid id), but a
          decoded message off {!Riptide_transport.Transport_intf.S}'s own "no payload integrity"
          wire has no such guarantee. Left unchecked, a single forged [StartViewChange] naming a
          non-existent replica id would inflate [Cardinality(recv_svc)] -- the exact same quorum-
          inflation bug class M1 (task-1-review.md) fixed for [Prepare_ok]'s own [i] field, just
          feeding [SendDVC]'s threshold instead of [is_committed_quorum]'s. [i = t.my_id] is
          excluded too: VSR.tla's own [BroadcastFunc] (VSR.tla:56, [replicas \ {source}]) makes
          [m.i = r] structurally unreachable for a [StartViewChange] a correct replica ever
          produces, but this codebase's simulated transport has no self-delivery special case
          ([lib/sim/network.ml]'s [send]/[pump_one] place a self-addressed message straight into
          the sender's own inbox) -- so without this exclusion, a self-addressed [StartViewChange]
          (not even a forgery, just an ordinary broadcast looping back) would count toward this
          replica's own quorum for free (task-2-review.md's M1, reproduced live: one genuine other
          plus one self-addressed message reached [SendDVC]'s threshold with only one real
          corroborator). Dropped WHOLESALE (no state change at all -- view_number/status untouched
          even if [v > view_number] would otherwise adopt it), exactly like a wrong-[i]
          [Prepare_ok]: simpler to reason about than applying every effect except the [recv_svc]
          write, and consistent with this module's established "guard failure => total no-op"
          convention. *)
  else if v > t.view_number then begin
    (* ReceiveHigherSVC (VSR.tla:183-194): a higher view than our own -- assume-mode, adopt it
       unconditionally (no majority needed to START a view change this way; see VSR.tla's own
       comment at ReceiveHigherSVC for the "assume-mode, not increment-mode" citation). *)
    t.view_number <- v;
    t.status <- View_change;
    t.recv_svc <- Int_set.singleton i;
    Hashtbl.reset t.recv_dvc;
    t.sent_dvc <- false;
    (* [rep_view_number] is DURABLE (VSR.tla:58-59, and [CrashRestart]'s own UNCHANGED list at
       :688-690 keeps it across a restart), and this is one of the four actions that moves it. It
       has to reach the superblock BEFORE this replica tells anyone it has adopted the new view --
       a replica that forgot an already-announced view bump across a restart would re-enter the
       old view, which is exactly what Decision 4's durable view/log_view pair exists to prevent. *)
    persist_superblock t;
    try_send_dvc t
  end
  else if v = t.view_number && t.status = View_change then begin
    (* ReceiveMatchingSVC (VSR.tla:196-205): another StartViewChange for the SAME episode we are
       already running -- accumulate. *)
    t.recv_svc <- Int_set.add i t.recv_svc;
    try_send_dvc t
  end
  else
    () (* Matches neither action's guard -- e.g. [v < view_number] (stale), or [v = view_number]
          while [status = Normal] (no view-change episode is running here to join) -- not enabled
          by anything, dropped, the same "no buffering/retry" discipline already established for
          an out-of-order Prepare. *)

(* ---- ValidDvc (VSR.tla:230) ----
   [ValidDvc(r, m) == m.v = View(r)] -- verbatim. This is the view-filtered DVC quorum-counting fix
   for the original formalization's own published 114-step safety counterexample (spec/tla/README.md,
   "What the ValidDvc filter is actually doing here"). It is applied in BOTH places VSR.tla applies
   it: as [ReceiveDVC]'s own guard (VSR.tla:235, in [handle_do_view_change] below) and AGAIN as a
   filter at every read (VSR.tla:258, 269 -- [valid_dvcs] below). The second application is
   currently inert in the abstract model, exhaustively (TLC: [RecvDvcValidWhenViewChange] holds on
   all 264,376 reachable states, because both actions that enter [View_change] reset [recv_dvc]
   first) -- spec/tla/README.md's own conclusion is that it stays anyway, since its redundancy is a
   property of the current reset discipline rather than of the protocol. Same conclusion here: the
   filter is kept, not optimized away. *)
let valid_dvc t (d : dvc) = d.dvc_v = t.view_number

(* The set VSR.tla writes as [{ m \in rep_recv_dvc[r] : ValidDvc(r, m) }] (VSR.tla:258, 269),
   materialized once per read. Sorted by sender id purely for DETERMINISM: [Hashtbl.fold]'s order
   is unspecified, and [winning_dvc] below resolves an exact [(last_normal_view, n)] tie by keeping
   whichever candidate it saw first -- VSR.tla's own [CHOOSE] is likewise free to return any
   maximal element, so sorting does not narrow the spec, it just makes THIS implementation's choice
   reproducible across runs (and therefore testable). *)
let valid_dvcs t =
  Hashtbl.fold (fun _ d acc -> if valid_dvc t d then d :: acc else acc) t.recv_dvc []
  |> List.sort (fun a b -> compare a.dvc_i b.dvc_i)

(* ---- WinningDVC (VSR.tla:248-255) ----
   [CHOOSE] the valid DVC for which no other valid DVC has either a strictly greater
   [last_normal_view], or an equal [last_normal_view] and a strictly greater [n] -- i.e. the
   lexicographic maximum by [(last_normal_view, n)], [last_normal_view] FIRST (research §2.4 step 3:
   "selects as the new log the one contained in the message with the largest v'; if several messages
   have the same v' it selects the one among them with the largest n"). Selecting by [n] alone is a
   real safety bug, not a simplification: a replica that stayed in an OLDER view can have a longer
   log than the replica that was most recently normal in the NEWEST view, and adopting the longer
   log would discard the newer view's committed entries.

   The fold keeps the incumbent on ties (STRICT [>] in both comparisons), so with [valid_dvcs]'s
   sort above, an exact [(last_normal_view, n)] tie resolves to the lowest sender id. *)
let winning_dvc (dvcs : dvc list) =
  match dvcs with
  | [] -> None (* unreachable from [try_send_sv]: its own [>= f + 1] guard implies a non-empty list *)
  | first :: rest ->
    Some
      (List.fold_left
         (fun best d ->
           if
             d.dvc_last_normal_view > best.dvc_last_normal_view
             || (d.dvc_last_normal_view = best.dvc_last_normal_view && d.dvc_n > best.dvc_n)
           then d
           else best)
         first rest)

(* ---- HighestCommitNumber (VSR.tla:257-260) ----
   A SEPARATE, INDEPENDENT maximum of [m.k] over the valid DVCs -- deliberately NOT derived from
   [winning_dvc]'s own result. VSR.tla:244-245 warns about exactly this in its own comment ("§5.7's
   explicit warning that HighestCommitNumber is a SEPARATE maximum, not derived from the winning
   DVC"), and this plan's Global Constraints repeat it: a future reader diffing this code against
   the spec must find two clearly separate scans. The winning DVC (chosen by [(last_normal_view, n)])
   routinely is NOT the DVC with the highest [k].

   [0] is a correct identity for the fold rather than a floor that could mask a negative: every
   entry in [recv_dvc] has passed [handle_do_view_change]'s own [k < 0] rejection below, and
   VSR.tla's [rep_commit_number] is typed [Nat] (VSR.tla:25, 325). *)
let highest_commit_number (dvcs : dvc list) =
  List.fold_left (fun acc d -> if d.dvc_k > acc then d.dvc_k else acc) 0 dvcs

(* ================= multi-step view-change completion (VSR.tla:403-516) =================
   The would-be primary of the new view collects DVCs, then resolves EVERY op in the candidate
   range before it may complete. VSR.tla:403-409 is explicit that this is structural rather than
   cosmetic: with storage faults, the evidence needed to complete may simply not have arrived yet,
   so the coordinator must be able to WAIT (stay in View_change, keep accepting DVCs -- what
   [try_send_sv] does by returning without effect) or GIVE UP ([try_forfeit_view_change]), and be
   interrupted at any point by a higher view (the existing [handle_start_view_change] path, which
   resets this whole accumulator).

   The functions below transcribe, in the spec's own order: HasDvcQuorum, EntrySources/CanFill/
   FillValue, NackCount/ProvenAbsent, ValidCompletion/CanComplete/CompletionPoint. *)

(* ---- HasDvcQuorum (VSR.tla:488-491) ----
   [Cardinality({ m.i : m \in ValidDvcs(r) }) >= Quorum] -- the [{ m.i : ... }] projection is THE
   POINT, and spec/tla/README.md records it as a real safety defect found by TLC at the widened
   bound, not a stylistic preference: counting MESSAGES lets one replica that sent two different
   DOVIEWCHANGEs in one episode look like a two-replica quorum, and the entire truncation argument
   ("a committed op is durably held by f+1 replicas, any two f+1 sets intersect") is a statement
   about f+1 DISTINCT REPLICAS that says nothing at all about f+1 messages.

   This module already had the right structure for the wrong-ish reason, and both reasons now
   apply: [recv_dvc] is a table KEYED BY SENDER with first-wins semantics (see its own doc comment
   on [t] -- originally motivated by the simulated transport's duplicate/corrupt injection), so
   [valid_dvcs] can contain at most one record per sender and its length already equals the
   distinct-sender count. The projection is nonetheless written out EXPLICITLY here, over
   [dvc_i], rather than left as [List.length dvcs]: the safety property is "distinct senders",
   the keying is an implementation detail that a future change to [recv_dvc]'s representation
   could alter, and the spec's own history on this exact line is the argument for not making a
   reader re-derive the equivalence. [nack_count] below projects the same way, for the same
   reason. *)
let dvc_senders (dvcs : dvc list) =
  List.fold_left (fun acc d -> Int_set.add d.dvc_i acc) Int_set.empty dvcs

let has_dvc_quorum t (dvcs : dvc list) =
  let f = (t.replica_count - 1) / 2 in
  t.status = View_change (* VSR.tla:489 *)
  && is_primary t (* VSR.tla:490: r = Primary(View(r)) *)
  && Int_set.cardinal (dvc_senders dvcs) >= f + 1
(* VSR.tla:491, Quorum == f + 1. Deliberately a separate expression from [try_send_dvc]'s own
   [>= f] threshold (VSR.tla:380, "f STARTVIEWCHANGE from OTHER replicas") -- two different
   citations, two different thresholds, never one shared constant that a later edit could drift. *)

(* ---- EntrySources / CanFill / FillValue (VSR.tla:440-444) ----
   [EntrySources(r, o) == { m \in ValidDvcs(r) : m.last_normal_view = CanonicalView(r) /\
                            o \in DOMAIN m.entries }]

   Replicas that share a log_view received their entries from the same primary, which assigns each
   op-number exactly once, so they cannot disagree about the value at an op -- that is what makes
   any same-log_view DVC an admissible source for an entry the WINNER itself cannot read, i.e. how
   a corrupt slot on the would-be primary gets repaired from a peer instead of forcing a
   truncation. Entries from a LOWER log_view are NOT admissible: those may be superseded values
   from an abandoned view. (VSR.tla's [DvcEntriesAgreeWithinLogView], :768-773, is the checked
   statement of the premise.)

   [FillValue]'s [CHOOSE] is free to return any source. This implementation prefers the WINNER's
   own entry when it has one, then the lowest sender id ([valid_dvcs] is sorted) -- both are legal
   refinements of [CHOOSE], and preferring the winner keeps the reconstructed log identical to the
   pre-storage-fault behaviour ("adopt the winner's log") in every fault-free execution, so a
   fault-free cluster's observable behaviour is unchanged by this task. *)
let entry_sources (dvcs : dvc list) ~(winner : dvc) ~op_number =
  let canonical_view = winner.dvc_last_normal_view (* CanonicalView(r), VSR.tla:432 *) in
  List.filter
    (fun d -> d.dvc_last_normal_view = canonical_view && List.mem_assoc op_number d.dvc_entries)
    dvcs

let can_fill (dvcs : dvc list) ~winner ~op_number = entry_sources dvcs ~winner ~op_number <> []

let fill_value (dvcs : dvc list) ~winner ~op_number =
  match entry_sources dvcs ~winner ~op_number with
  | [] -> None
  | sources -> (
    match List.assoc_opt op_number winner.dvc_entries with
    | Some v -> Some v
    | None -> List.assoc_opt op_number (List.hd sources).dvc_entries)

(* ---- NackCount / ProvenAbsent (VSR.tla:452-453) ----
   [NackCount(r, o) == Cardinality({ m.i : m \in { d \in ValidDvcs(r) : o \in d.nacks } })] --
   again projected onto DISTINCT SENDERS, and again written out explicitly rather than as a list
   length. An op nacked by f+1 distinct replicas cannot have been committed (committing needs f+1
   replicas to have durably held it, any two f+1 sets of 2f+1 intersect, and a replica that
   durably held an entry can never nack it), which is exactly what makes dropping it safe.

   [sender_proves_absent] is where this transcription spends the equivalence [provable_nacks]
   documents: a DVC proves op [o] absent either explicitly (it is in the message's own [nacks]
   set) or structurally (it lies above the sender's own durable op-number [n], which by
   [StorageWellFormed] (VSR.tla:742-745) and [LogLengthMatchesOpNumber] (:728-729) is PRECISELY
   the condition [CanNack] tests). The second disjunct is not an extra liberty taken on top of the
   spec -- it is the spec's own [CanNack], restated in the only form a real, unbounded op-number
   space can carry it in. Today it is also the ONLY disjunct that ever fires.

   The [List.mem] disjunct is, as of today, STRUCTURALLY REDUNDANT rather than a second source of
   evidence -- it refines nothing. [nacks_wellformed] (:1405, reached via [handle_do_view_change])
   drops any DVC carrying a nack at or below the sender's own [n] wholesale, so every nack that
   survives validation already satisfies [op_number > d.dvc_n], which is precisely the first
   disjunct. An accepted nack therefore cannot contradict [n], cannot refine it, and cannot add
   anything to it. It is kept because the wire field is real and the membership test costs
   nothing, NOT because it extends what [n] already carries, and NOT as a hook a future storage
   layer could light up on its own.

   That redundancy is load-bearing in two places: it makes [sender_proves_absent] monotone in
   [op_number] (what makes [completion_point]'s downward-scan bound exact, not a heuristic cap),
   and it is what lets [provable_nacks] (:496) be provably empty on the sender side with no
   receiver losing any evidence. Reporting genuine in-range holes means relaxing
   [nacks_wellformed] in the same change that widens [provable_nacks] -- see that function's own
   comment for why the sender-only version would wedge the protocol. *)
let sender_proves_absent (d : dvc) ~op_number = op_number > d.dvc_n || List.mem op_number d.dvc_nacks

let nack_count (dvcs : dvc list) ~op_number =
  Int_set.cardinal
    (List.fold_left
       (fun acc d -> if sender_proves_absent d ~op_number then Int_set.add d.dvc_i acc else acc)
       Int_set.empty dvcs)

let proven_absent t (dvcs : dvc list) ~op_number =
  let f = (t.replica_count - 1) / 2 in
  nack_count dvcs ~op_number >= f + 1 (* VSR.tla:453, Quorum == f + 1 *)

(* ---- ValidCompletion / CanComplete / CompletionPoint (VSR.tla:459-471) ----
   [ValidCompletion(r, L)] is three clauses: [L >= HighestCommitNumber(r)], every op in [1..L]
   fillable, every op in [(L+1)..WinningDVC(r).n] proven absent. An op in neither category is
   CONTESTED and blocks completion outright ("a quorum simply hasn't reported yet (must wait)").
   [CanComplete] is the existence of such an [L]; [CompletionPoint] is the LONGEST one, because
   truncation is a last resort taken only where a nack quorum forces it.

   Computed here in one pass each rather than by searching [0..n] and re-checking both universal
   quantifiers per candidate, which is the same set by a cheaper route:

     - [fillable_prefix] = the largest [p] with every op in [1..p] fillable. Every admissible [L]
       is [<= fillable_prefix], and [fillable_prefix] itself satisfies the fillability clause.
     - [highest_contested] = the largest op in [1..n] NOT proven absent (0 if all are). Every
       admissible [L] is [>= highest_contested], since an op above [L] that is not proven absent
       violates the third clause.

   So the admissible set is exactly the integers in [[max(highest_commit, highest_contested),
   fillable_prefix]], and its maximum -- CompletionPoint -- is [fillable_prefix] whenever that
   interval is non-empty. Returning [None] for an empty interval is [~CanComplete], which is
   precisely [try_forfeit_view_change]'s own enabling condition below. *)
let completion_point t (dvcs : dvc list) ~(winner : dvc) ~highest_commit =
  let f = (t.replica_count - 1) / 2 in
  let n = winner.dvc_n in
  let rec fillable_prefix o = if o > n || not (can_fill dvcs ~winner ~op_number:o) then o - 1 else fillable_prefix (o + 1) in
  (* WHERE THE DOWNWARD SCAN STARTS, and why it is not simply [n]. [n] is a decoded field: a
     forged DoViewChange may claim an op-number of 10^9 with no way for a receiver to disprove it
     (unlike the old wire format, [n] is no longer bounded by the length of a log carried in the
     same message -- [entries] is partial now, so it cannot bound [n] any more). Scanning down from
     [n] is then a real denial of service, not a slow path: with the winner claiming 10^9 and f+1
     honest senders reporting small [n]s, EVERY op down to their own op-numbers genuinely is
     proven absent, so the scan does not exit early -- it walks a billion op-numbers inside
     [handle_message]. Reproduced as a hanging test before this bound existed, and pinned by
     [test_forged_huge_n_does_not_hang].

     The bound is exact, not a heuristic cap. Sort the senders' op-numbers ascending; an op [o] is
     structurally proven absent by [sender_proves_absent]'s [o > d.dvc_n] disjunct exactly when
     more than f of them are below it, i.e. for every [o > n_(f+1)] (the (f+1)-th smallest). So
     every op in [(n_(f+1), n]] is already proven and cannot be the highest contested one; the
     search may start at [min(n, n_(f+1))] and lose nothing. Explicit nacks can only prove MORE
     ops absent, so they can only push the answer further down -- which is why the loop below still
     runs, but now for at most (number of explicit nacks + 1) steps rather than for [n] of them.

     COUPLING TO WATCH: the [f] index below IS [proven_absent]'s own [f + 1] quorum, restated as
     "the (f+1)-th smallest". Raising one threshold without the other would make this skip a range
     it only ASSUMES is proven -- so if [proven_absent]'s quorum ever changes, this must change
     with it. (Lowering only [proven_absent] stays sound, since the skipped range would then be
     proven a fortiori; raising it does not.) *)
  let structural_threshold =
    match List.nth_opt (List.sort compare (List.map (fun d -> d.dvc_n) dvcs)) f with
    | Some n_q -> n_q
    | None -> n (* fewer than f+1 senders: nothing is structurally proven. Unreachable from both
                   callers, which check [has_dvc_quorum] first. *)
  in
  let rec highest_contested o =
    if o < 1 then 0 else if proven_absent t dvcs ~op_number:o then highest_contested (o - 1) else o
  in
  let start = min n structural_threshold in
  let contested =
    (* The skip above is an ARGUMENT about [proven_absent], so it is checked against
       [proven_absent] rather than trusted: if the first skipped op is not actually proven absent,
       the argument does not hold here and the skipped range is treated as contested (blocking the
       completion) instead of silently assumed away. One extra call, and it is what keeps this
       optimization from becoming a second, drifting definition of the nack rule -- a mutation
       that deletes [sender_proves_absent]'s structural disjunct is caught here rather than
       masked. Every op above the first skipped one is covered by the same threshold argument, so
       checking the boundary is checking the claim. *)
    if start < n && not (proven_absent t dvcs ~op_number:(start + 1)) then start + 1
    else highest_contested start
  in
  let longest = fillable_prefix 1 in
  if longest >= max highest_commit contested then Some longest else None

(* ---- SendSV (VSR.tla:499-516) ----
   Driven from [handle_do_view_change] ([ReceiveDVC]) below, mirroring [try_send_dvc]'s own
   established "drive the derived action from every point its enabling condition can change"
   pattern: [ReceiveDVC] is the only action that adds evidence, and evidence is all this guard
   reads. [check_timeout]/[handle_start_view_change] need no call because both set [recv_dvc] to
   EMPTY in the same step, making the quorum conjunct provably false immediately afterwards for
   EVERY [replica_count] (the threshold is [f + 1 >= 1 > 0]).

   Two conjuncts now, not one (VSR.tla:501-502): [HasDvcQuorum(r)] AND [CanComplete(r)]. And the
   new log is reconstructed op-by-op from [FillValue] rather than copied wholesale from the winner
   -- because the winner may not be able to read all of its own entries, which is the entire
   reason [entries] is a partial function on the wire. *)
let try_send_sv t =
  let dvcs = valid_dvcs t in
  if not (has_dvc_quorum t dvcs) then ()
  else
    match winning_dvc dvcs with
    | None -> () (* unreachable, see [winning_dvc]: the quorum guard implies a non-empty list *)
    | Some winner ->
      let new_k = highest_commit_number dvcs in
      if new_k > winner.dvc_n then
        () (* DEFENSIVE, NOT IN VSR.tla, and now SUBSUMED by [completion_point] (no [L <=
              winner.dvc_n] can satisfy [L >= highest_commit] when [highest_commit > winner.dvc_n],
              so [CanComplete] is already false) -- kept as its own explicit, separately-cited
              branch because it states a DIFFERENT property than the completion arithmetic does:
              some valid DVC claims a commit_number beyond the end of the log this view is about to
              adopt, which no well-formed DVC set can produce and which only CROSS-message
              comparison can expose (each message is already field-validated on arrival). Refused
              wholesale rather than clamped to [winner.dvc_n]: clamping targets the maximum legal
              value, i.e. it would declare the entire adopted log committed off the back of one
              corrupted integer. The cost of refusing is liveness, and it is NOT bounded to one
              episode -- a backup whose own commit_number was inflated by a corrupted Prepare
              re-sends that [k] in every later episode's DVC -- but it is a liveness cost, where
              both alternatives are safety costs. EVIDENCE it never fires for well-formed traffic:
              TLC over the shipped bound with [T3_SendSvCommitWithinWinnerLog], 553,084 states
              generated / 264,376 distinct, no violation, with a companion vacuity check confirming
              SendSV really is enabled in that graph. *)
      else (
        match completion_point t dvcs ~winner ~highest_commit:new_k with
        | None ->
          () (* ~CanComplete: at least one op in the candidate range is neither reconstructible
                from canonical evidence nor proven absent by a nack quorum. WAIT -- stay in
                View_change with all evidence intact and keep accepting DVCs; more DVCs can only
                ADD evidence, never remove it. Giving up is a separate, timer-driven decision
                ([try_forfeit_view_change] below), never something this send path takes on its
                own. *)
        | Some l -> (
          let rec build o acc =
            if o > l then Some (List.rev acc)
            else
              match fill_value dvcs ~winner ~op_number:o with
              | Some v -> build (o + 1) (v :: acc)
              | None -> None (* unreachable: [completion_point] returned [l], so every op in
                                [1..l] has a source. Handled rather than asserted, per this
                                module's "guard failure => total no-op" convention. *)
          in
          match build 1 [] with
          | None -> ()
          | Some new_log ->
            (* VSR.tla:509's [rep_storage' = FreshStorage(L)]: the new primary has just durably
               written and verified the canonical log. Done FIRST, so that a backend that refuses
               the write leaves this action a total no-op instead of a replica whose in-memory
               state claims a completion its disk never took. *)
            if adopt_durable_log t new_log ~committed:new_k then begin
              Replica_log.replace_with t.log new_log (* VSR.tla:506 *);
              t.op_number <- l (* VSR.tla:507 -- now an explicit assignment, since [op_number] is
                                  its own durable field rather than the log's length *);
              advance_commit_number t new_k;
              (* VSR.tla:508 -- unconditional, NOT monotonic-guarded: unlike [ReceiveSV]'s own
                 update, this replica is the one STARTING the new view, and [new_k] is the maximum
                 over a quorum's worth of DVCs including (normally) its own. Pinned by
                 [test_vsr_replica.ml]'s own
                 [test_send_sv_commit_number_assignment_is_unconditional_not_monotonic].

                 The cross-message hazard an earlier version of this comment disclosed as
                 KNOWINGLY UNGUARDED -- nothing checked the adopted log's length against THIS
                 replica's own pre-existing [commit_number] -- is now guarded, but by the spec's
                 own clause rather than by a bolted-on check: [ValidCompletion]'s
                 [L >= HighestCommitNumber(r)] (VSR.tla:460) is exactly that bound, stated against
                 the commit-number this step establishes ([new_k]) rather than against the one it
                 replaces. [adopt_durable_log] re-checks it on the durable side through
                 [truncate_wal]'s own [~committed] argument, which is the Review Focus guard. Note
                 what this deliberately does NOT do: it does not refuse a completion whose [L] is
                 below the coordinator's OWN prior [commit_number], because that is precisely the
                 unconditional assignment above, and the two would fight. *)
              t.last_normal_view <- t.view_number (* VSR.tla:511 *);
              t.svc_count <- 0
              (* Disclosed divergence -- see [svc_count]'s own doc comment on [t]. Unconditional
                 here because [HasDvcQuorum] already restricts this action to [status =
                 View_change], so reaching this point IS a real View_change -> Normal transition. *);
              t.status <- Normal (* VSR.tla:510 *);
              persist_superblock t;
              let bytes =
                Message.encode
                  (Message.Start_view { v = t.view_number; log = new_log; n = l; k = new_k; source = t.my_id })
              in
              (* VSR.tla:512-513's own [Broadcast(..., r)] -- every OTHER replica, never self
                 (VSR.tla:177's [replicas \ {source}]). *)
              for peer = 1 to t.replica_count do
                if peer <> t.my_id then t.send ~to_:peer bytes
              done
            end))

(* ---- ForfeitViewChange (VSR.tla:542-556) ----
   Enabled precisely when this replica has everything the OLD, storage-fault-unaware protocol
   needed to complete -- primary of its own view, in View_change, holding a valid f+1 DVC quorum --
   and STILL cannot complete, because at least one op in the candidate range is neither
   reconstructible nor proven absent. That is the one situation storage-fault-awareness newly
   creates and that no amount of waiting is GUARANTEED to resolve: the remaining f replicas may
   all be unreachable, or may all report the same corrupt slot.

   Effect: abandon this attempt at view+1 so a different replica -- one whose storage may be
   intact where this one's is not -- gets to coordinate. The replica STAYS in View_change; it does
   not fall back to Normal, because its durable view has already advanced.

   Deliberately NOT enabled below a DVC quorum (VSR.tla:528-531): more DVCs only ever add
   evidence, so forfeiting early would abandon an attempt that was still making progress.

   TWO DELIBERATE DIVERGENCES from the literal spec text, both disclosed:

   1. WHO DRIVES IT. In TLA+ this is an always-enabled disjunct of [Next], free to fire the
      instant the quorum is reached. Firing it eagerly here would be wrong for a real deployment
      -- the f+1st DVC and the DVC that resolves the contested op can arrive microseconds apart,
      and an eager forfeit would abandon a completable view change every time. VSR.tla:536-537
      says as much ("Bounded by ForfeitLimit ...; a real implementation bounds it with a timer"),
      so this is driven from [check_timeout]: the caller's own "nothing is progressing" signal.
   2. WHAT BOUNDS IT. The spec's [aux_forfeit_count < ForfeitLimit] is a state-space device. Here
      the budget is [svc_count]/[svc_limit], shared with [TimerSendSVC] -- both are "this replica
      gives up on the current view and tries to start a newer one", both are reset by a successful
      return to Normal, and giving forfeits a second, independent budget would let a wedged
      replica burn view numbers at twice the configured rate for no stated reason. *)
let try_forfeit_view_change t =
  let dvcs = valid_dvcs t in
  if not (has_dvc_quorum t dvcs) then ()
  else
    let can_complete =
      match winning_dvc dvcs with
      | None -> false
      | Some winner ->
        let new_k = highest_commit_number dvcs in
        new_k <= winner.dvc_n && completion_point t dvcs ~winner ~highest_commit:new_k <> None
    in
    if can_complete then
      () (* [~CanComplete(r)] is the other half of VSR.tla:545-546's guard: with a quorum that CAN
            complete, [SendSV] is the enabled action, not this one. Reached only if a caller fires
            the timer between the arrival of the completing evidence and the send -- which cannot
            happen through [handle_message], since [try_send_sv] runs in the same call. *)
    else begin
      let v = t.view_number + 1 in
      t.view_number <- v (* VSR.tla:548 *);
      t.recv_svc <- Int_set.empty (* VSR.tla:549 *);
      Hashtbl.reset t.recv_dvc (* VSR.tla:550 *);
      t.sent_dvc <- false (* VSR.tla:551 *);
      t.svc_count <- t.svc_count + 1 (* see divergence 2 above *);
      (* [rep_status] is deliberately absent from the effects: VSR.tla:554-555 lists it UNCHANGED,
         and it is already "ViewChange" by [HasDvcQuorum]'s own first conjunct. *)
      persist_superblock t;
      let bytes = Message.encode (Message.Start_view_change { v; i = t.my_id }) in
      for peer = 1 to t.replica_count do
        if peer <> t.my_id then t.send ~to_:peer bytes
      done
    end

(* ---- TimerSendSVC (VSR.tla:302-315), plus the forfeit escape's trigger ----
   research §2.1: VSR.tla deliberately does not model real timeouts -- this is an unconditional,
   always-enabled (once its guard holds) action, not something driven by a clock; a caller decides
   when to invoke [check_timeout] (e.g. on an actual timer firing with no Prepare/heartbeat seen
   recently), matching the spec's own framing of it as "bounded by a state-space-limiting counter"
   rather than real wall-clock logic.

   ONE ENTRY POINT, TWO ACTIONS, selected by status -- and they are disjoint by construction:
   [TimerSendSVC] guards on [rep_status[r] = "Normal"] (VSR.tla:305) and [ForfeitViewChange]'s own
   [HasDvcQuorum] guards on [rep_status[r] = "ViewChange"] (VSR.tla:489), so no call can ever
   trigger both. Keeping them behind one function is what makes the caller's contract "tell the
   replica that nothing has progressed recently" rather than "know which recovery action is
   currently applicable", which the caller has no way to determine. *)
let check_timeout t =
  if t.svc_count >= t.svc_limit then
    () (* [aux_svc_count[r] < StartViewOnTimerLimit] guard (VSR.tla:304) -- see [svc_count]'s own
          doc comment on [t] for why this bound is NOT permanent in this implementation despite
          [aux_svc_count] never resetting in the literal TLA+ transcription: [SendSV]/[ReceiveSV]
          reset it to 0 on every successful return to [Normal], giving each new failure its own
          fresh budget. Bounds the forfeit path too -- see [try_forfeit_view_change]'s divergence
          2. *)
  else if t.status = View_change then try_forfeit_view_change t
  else begin
    let v = t.view_number + 1 in
    t.view_number <- v;
    t.status <- View_change;
    t.recv_svc <- Int_set.empty;
    Hashtbl.reset t.recv_dvc;
    t.sent_dvc <- false;
    t.svc_count <- t.svc_count + 1;
    persist_superblock t
    (* [rep_view_number] is durable (VSR.tla:58-59); on disk before the new view is announced, for
       the same reason [handle_start_view_change]'s own bump is. *);
    let bytes = Message.encode (Message.Start_view_change { v; i = t.my_id }) in
    for peer = 1 to t.replica_count do
      if peer <> t.my_id then t.send ~to_:peer bytes
    done;
    try_send_dvc t (* see try_send_dvc's own doc comment for why this call is included *)
  end

(* ---- ReceiveDVC (VSR.tla:232-240) ----
   Guard: [ValidDvc(r, m)] and nothing else -- in particular NO status conjunct (a DVC matching this
   replica's current view is accumulated even while [status = Normal], exactly as in the spec; the
   sole reader, [try_send_sv], carries the [status = View_change] check instead) and no
   [r = Primary(View(r))] conjunct (VSR.tla relies on [m.dest] for that; a misrouted DVC simply
   accumulates on a non-primary, where nothing ever reads it).

   Every integer field is validated before being trusted, matching the precedent already
   established twice in this module ([handle_prepare_ok]'s [i]/[n], [handle_prepare]'s [k]):
   [Message.decode] confirms a message's SHAPE, never its protocol-level legality, and
   {!Riptide_transport.Transport_intf.S} promises no payload integrity. Each check below is
   accompanied by the property of the sending replica it re-establishes, and each was confirmed
   INERT for correct traffic by TLC on a scratch copy of spec/tla/VSR.tla (invariant
   [T3_DvcFieldsWellFormed]: every DoViewChange record in the message bag satisfies
   [Len(m.log) = m.n /\ m.k <= m.n /\ m.last_normal_view < m.v /\ m.i \in replicas]) -- no
   violation over the full 264,376-distinct-state graph, with a companion vacuity check confirming
   DoViewChange messages really do occur there. *)
let handle_do_view_change t ~(v : int) ~(entries : (int * Value.value) list) ~(nacks : int list)
    ~(last_normal_view : int) ~(n : int) ~(k : int) ~(i : int) =
  (* [entries] is a partial map, so it is validated as one: every op-number inside the sender's
     own [1..n] range, and no op-number twice. Both checks are load-bearing rather than tidiness.
     An out-of-range key would let a forged DVC supply a value for an op outside the range the
     completion arithmetic reasons about (and, at [o <= 0], for an op-number that cannot exist at
     all -- VSR.tla's [ops == 1..MaxOp] is 1-indexed). A DUPLICATE key would make [List.assoc]'s
     first-wins silently decide which of two values for the SAME op-number this coordinator
     reconstructs the cluster's log from, which is a log-content decision taken by message
     ordering rather than by the protocol. *)
  let entries_wellformed =
    let rec loop seen = function
      | [] -> true
      | (o, _) :: rest -> if o < 1 || o > n || List.mem o seen then false else loop (o :: seen) rest
    in
    loop [] entries
  in
  (* THE NACK RANGE CHECK (this plan's own Review Focus list, Task 7: "a nack referencing an
     op-number outside any replica's real log range ... must be handled as a malformed/out-of-range
     input without crashing, matching this codebase's established 'guard failure => total no-op'
     convention").

     The range a nack must fall in is [o > n] (and [o >= 1]), NOT [1..n] and not the RECEIVER's own
     op-number range. Both narrower readings are wrong in a way worth recording, because the
     natural-looking one is the dangerous one:

     - [o] at or below the SENDER's own [n] is exactly the forgery this check exists to stop. By
       [StorageWellFormed] (VSR.tla:742-745) + [LogLengthMatchesOpNumber] (:728-729), [CanNack(r,
       o)] holds precisely for [o > rep_op_number[r]], so a nack within the sender's own claimed
       log range is a self-contradiction -- the message says in one field that it durably holds op
       [o] and in another that it can prove it never did. Accepting it would let one forged DVC
       supply a nack for a COMMITTED op, which is one half of a false [ProvenAbsent] quorum.
     - Bounding by the RECEIVER's own op-number would reject the legitimate, load-bearing case:
       nacks for ops ABOVE this replica's own log are precisely the evidence that licenses
       truncating the winning DVC's longer log down to [CompletionPoint]. A coordinator whose own
       log is short would refuse exactly the messages it needs.

     A nack far above [n] (the "outside any replica's real log range" case) is therefore ACCEPTED
     and provably inert: the completion arithmetic only ever asks about ops in [1..WinningDVC.n],
     nothing is indexed or allocated per nack, and [sender_proves_absent] already treats every op
     above [n] as proven regardless. *)
  let nacks_wellformed = List.for_all (fun o -> o >= 1 && o > n) nacks in
  if i < 1 || i > t.replica_count then
    () (* VSR.tla:15's own [replicas == 1..ReplicaCount]. Note this check does NOT exclude
          [i = t.my_id], unlike [handle_start_view_change]'s otherwise-identical-looking check: a
          DOVIEWCHANGE from this replica to itself is entirely legitimate and REQUIRED -- VSR.tla:224
          addresses it to [Primary(View(r))], which is this replica whenever it is the new primary,
          and VSR.tla:262-263's quorum is "f+1 ... from different replicas, INCLUDING ITSELF".
          Excluding self here would make [SendSV] need f+1 OTHER replicas, i.e. a strictly larger
          quorum than the protocol specifies, and would stall every view change in a cluster with
          exactly f+1 survivors. *)
  else if v <> t.view_number then
    () (* ValidDvc(r, m) == m.v = View(r) (VSR.tla:230, 235) -- a DVC for any other view, higher or
          lower, is matched by no action and dropped. For a HIGHER view this is a deliberate,
          already-analyzed liveness simplification, not an oversight (spec/tla/README.md's own
          known-simplifications list, and VSR.tla:176-182's own scope note): a DOVIEWCHANGE is
          unicast, so any view it could announce was already broadcast to everyone as a
          STARTVIEWCHANGE first. *)
  else if n < 0 then
    () (* [rep_op_number] is typed [Nat] (VSR.tla:53).

          NOTE WHAT IS NO LONGER CHECKED HERE, since it is the one validation this task removed:
          the old [n <> List.length log] check, which required the message's op-number to equal
          the length of the log it carried. That is no longer a property of a well-formed
          DoViewChange: [entries] is a PARTIAL function over [1..n] (VSR.tla:381-382), so
          [Cardinality(DOMAIN m.entries) < m.n] is exactly what a replica with an unreadable slot
          reports, and [n] itself comes from durable superblock state that stays trustworthy when
          entry bodies do not (VSR.tla:358-359). The property the old check protected --
          [LogLengthMatchesOpNumber] on the log this coordinator ends up adopting -- is now
          established constructively instead: [try_send_sv] builds the new log as ops [1..L] from
          [FillValue] and assigns [op_number <- L] in the same step, so its length and op-number
          agree by construction rather than by trusting a sender's field. The in-range/no-duplicate
          check on [entries] above is what keeps that construction well-defined. *)
  else if not entries_wellformed then
    () (* see [entries_wellformed] above *)
  else if not nacks_wellformed then
    () (* see [nacks_wellformed] above -- THE REVIEW FOCUS GUARD. Dropped WHOLESALE (no entry is
          recorded, no field is applied, nothing is sent), per this module's established "guard
          failure => total no-op" convention, rather than by filtering the offending nacks out of
          an otherwise-accepted message: a DVC that contradicts its own [n] is evidence about the
          sender's trustworthiness, not a message with one bad field. *)
  else if k < 0 || k > n then
    () (* [CommitNumberNeverHigherThanOpNumber] (VSR.tla:330-331) applied to the sender's own state.
          Note [<=], not [<], is the right bound HERE, unlike [handle_prepare]'s [k < n]: a DVC's
          [k] and [n] are the sender's own commit_number and op_number, which legitimately coincide
          on a fully-committed replica, whereas a Prepare's [k] is the primary's commit_number from
          strictly before the entry that same message carries. This is the single field
          [HighestCommitNumber] maximizes over, so an unbounded [k] here is the most direct route to
          a cluster-wide [CommitNumberNeverHigherThanOpNumber] violation via [StartView.k]. *)
  else if last_normal_view < 0 || last_normal_view >= v then
    () (* [last_normal_view] is the PRIMARY sort key [WinningDVC] selects the surviving log by, so an
          unbounded value here lets one forged DVC dictate the entire cluster's log -- the most
          safety-critical field on this message type. A correct sender's [last_normal_view] is
          always STRICTLY below the view its DOVIEWCHANGE announces: [SendDVC] requires
          [status = "ViewChange"] (VSR.tla:219), [last_normal_view] is only ever written by
          [SendSV]/[ReceiveSV] (which set [status = "Normal"] in the same step, VSR.tla:275-276,
          301-302), and both actions that ENTER "ViewChange" raise [view_number] strictly above the
          replica's current view without touching [last_normal_view] (VSR.tla:166-167, 187-188).
          Confirmed exhaustively rather than argued: TLC on a scratch copy of VSR.tla with
          [T3_ViewChangeImpliesLastNormalViewBelowView] ([status = "ViewChange" =>
          last_normal_view < view_number]) found no violation across all 264,376 distinct reachable
          states, and the matching [T3_DvcFieldsWellFormed] conjunct checks the property on the
          DOVIEWCHANGE records themselves. *)
  else begin
    let d =
      {
        dvc_v = v;
        dvc_entries = entries;
        dvc_nacks = nacks;
        dvc_last_normal_view = last_normal_view;
        dvc_n = n;
        dvc_k = k;
        dvc_i = i;
      }
    in
    (* FIRST-WINS, per sender, per EPISODE -- see [recv_dvc]'s own doc comment on [t] for the full
       reasoning. [already_this_episode] deliberately checks the stored entry's own [dvc_v] rather
       than mere key presence: an entry left over from an older view (only reachable via
       [handle_start_view], the one action that raises [view_number] without clearing this table)
       belongs to no current episode and must not shadow a genuinely current DVC from the same
       sender. That shadowing would in fact be harmless today -- any entry present while
       [status = Normal] is wiped by whichever action next enters [View_change], before
       [try_send_sv] can read it -- but the check costs one comparison and removes the need for a
       future reader to re-derive that argument. *)
    let already_this_episode =
      match Hashtbl.find_opt t.recv_dvc i with Some existing -> existing.dvc_v = t.view_number | None -> false
    in
    if not already_this_episode then begin
      Hashtbl.replace t.recv_dvc i d (* VSR.tla:236's own [@ \cup {m}], keyed by sender *);
      try_send_sv t
      (* [ReceiveDVC] is the ONLY action that raises [Cardinality({valid DVCs})], so this is the
         only point [SendSV]'s threshold can newly become satisfied -- see [try_send_sv]'s own
         comment for why no other call site is needed. Deliberately inside this branch: an ignored
         duplicate changes nothing the guard reads. *)
    end
  end

(* ---- ReceiveSV (VSR.tla:292-305) ---- *)
let handle_start_view t ~(v : int) ~(log : Value.value list) ~(n : int) ~(k : int) ~source =
  if v < 0 then () (* [rep_view_number] is typed [Nat] (VSR.tla:30, 326) *)
  else if v < t.view_number then
    () (* VSR.tla:295's own guard is [m.v >= View(r)] -- [>=], NOT [>]: a StartView for the view
          this replica is ALREADY in is accepted and re-applied (that is what makes the conditional
          [svc_count] reset below necessary, per task-3-brief.md's resolved decision 3). Only a
          strictly LOWER view is dropped. There is deliberately no status conjunct either. *)
  else if source <> primary_of_view ~replica_count:t.replica_count v then
    () (* Finding 3 of the audit-remediation Task 3 fix round -- the reproduction of the audit's
          own single highest-severity finding that sender-authentication ALONE does not close:
          [handle_message]'s cross-check only proves [source] is who transport-authenticated
          [sender] genuinely is, never that this real, credentialed replica had any business
          announcing a [StartView] for view [v] at all. Any OTHER real cluster member -- no
          identity spoofing needed, just its own true id -- could otherwise rewrite this replica's
          entire committed log by sending a well-formed [StartView] under itself. [primary_of_view
          v], not [primary t]: unlike [handle_prepare]'s check above, [v] here is the message's
          OWN claimed view, not necessarily [t.view_number] (VSR.tla:295's guard is [m.v >=
          View(r)], so a [StartView] for a view strictly ahead of this replica's own is exactly
          the normal, expected case a lagging replica must accept -- checking [source] against
          [primary t] would wrongly reject every legitimate such message, since [primary t] is
          Primary of the OLD view, not the one actually being announced). Checked here, before
          [n]/[log]/[k] are even inspected, so a message from a real-but-wrong-view-primary sender
          is dropped as a total no-op exactly like every other guard in this function, never
          adopting so much as one byte of the log it carries. *)
  else if n < 0 || n <> List.length log then
    () (* Same [LogLengthMatchesOpNumber] check, same reason, as [handle_do_view_change]'s: this
          log is adopted wholesale and its length BECOMES this replica's op_number. TLC-confirmed
          inert for correct traffic ([T3_SvFieldsWellFormed]). *)
  else if k < 0 || k > n then
    () (* [CommitNumberNeverHigherThanOpNumber] for the state this message is asking us to adopt:
          [k] is the new primary's [HighestCommitNumber] and [n] the winning log's length. *)
  else if n < t.commit_number then
    () (* DEFENSIVE, NOT IN VSR.tla, and inert for every correct execution the model can reach:
          refuse a StartView whose log is SHORTER than what this replica has already committed.
          Adopting it would discard committed entries outright (real data loss, and it would leave
          [commit_number > op_number] here the moment the monotonic update below keeps our own
          higher value). EVIDENCE: TLC on a scratch copy of VSR.tla with
          [T3_ReceiveSvNeverTruncatesBelowCommit] (ReceiveSV enabled => [m.n >= rep_commit_number[r]])
          found no violation across the full 264,376-distinct-state graph, with a companion vacuity
          check confirming receivable StartViews with [m.v >= View(r)] really do occur. So this
          rejects nothing a correct primary ever sends -- it is purely a bound on forged/corrupted
          input. Dropped WHOLESALE (view_number/status untouched), per this module's "guard failure
          => total no-op" convention. *)
  else if
    not
      (adopt_durable_log t log ~committed:(max t.commit_number k)
      (* VSR.tla:573's [rep_storage' = FreshStorage(m.n)]: adopting the canonical log means durably
         writing and verifying it, which is how a corrupt slot on THIS replica gets repaired. Done
         before any in-memory effect, so a backend that refuses the write leaves the action a total
         no-op. [~committed] is the commit-number in effect AFTER this step (the monotonic update
         below can only raise it), so the Review Focus truncate guard is checked against the value
         this replica will actually be claiming, not the one it is leaving behind. *))
  then ()
  else begin
    Replica_log.replace_with t.log log (* VSR.tla:571-572: log and op_number adopted wholesale *);
    t.op_number <- n;
    if k > t.commit_number then advance_commit_number t k;
    (* VSR.tla:298-299's own [IF m.k > @ THEN m.k ELSE @] -- MONOTONIC ONLY. research §5.7 Part 4:
       applying [m.k] unconditionally is a REAL, documented defect (it caused a
       double-application-of-an-operation bug in the original published spec). Do not simplify this
       back to an unconditional assignment. The [k <= n] bound checked above is what keeps the
       result [<= op_number] in the OTHER direction, for a forged [k]. *)
    t.view_number <- v (* VSR.tla:300 *);
    t.last_normal_view <- v (* VSR.tla:302 *);
    if t.status = View_change then t.svc_count <- 0;
    (* Disclosed divergence (see [svc_count]'s doc comment on [t]), and CONDITIONAL here on a real
       View_change -> Normal transition -- task-3-brief.md's resolved decision 3. VSR.tla:295's
       guard has no status conjunct, so this action genuinely fires on a duplicated/replayed
       StartView for a view this replica is already Normal in; an unconditional reset would let such
       duplicates refresh the timeout budget indefinitely and quietly nullify [svc_limit]. Must be
       read BEFORE the [status <- Normal] write below. *)
    t.status <- Normal (* VSR.tla:577 *);
    persist_superblock t
    (* One write for all four durable fields this action moves (op_number, commit_number,
       view_number, last_normal_view), AFTER the WAL has already been rewritten by
       [adopt_durable_log] -- see that function's own CRASH ORDERING note for why this order is
       the conservative one. *)
    (* [recv_dvc] and [recv_svc] are deliberately NOT reset -- VSR.tla:304 lists both as UNCHANGED,
       and spec/tla/README.md ("What the ValidDvc filter is actually doing here") has the detailed,
       TLC-backed argument for why the stale entries this genuinely leaves behind can never be READ:
       every reader is gated on [status = View_change], and both actions that reach that status
       ([check_timeout], [handle_start_view_change]'s higher-view branch) reset both structures
       first. Adding a reset here would deviate from the model this code is required to match, in a
       direction the model was never checked against. Do not "fix" it. *)
  end

(* Finding 1 of the audit-remediation Task 3 fix round: this used to be [invalid_arg], overloading
   the SAME exception [durable_append] above (line ~714/720) already uses for a genuinely different
   condition -- an unclassified backend refusal escaping [durable_append] on purpose, precisely so
   it is NEVER laundered into "the protocol declined an op" (see that function's own comment). A
   caller that must stay total in the face of BOTH (e.g. {!Riptide_dst.Cluster}'s dispatch loop)
   could not tell the two apart by exception type alone, so a blanket [Invalid_argument] catch there
   -- added for the sender-mismatch case below -- silently absorbed a real backend-contract
   violation too, exactly the laundering that comment warns against. A distinct exception fixes
   this: nothing else in this module raises it, so a caller catching it exactly (not [Invalid_argument])
   absorbs ONLY a sender-mismatch, and [durable_append]'s own [Invalid_argument] propagates
   unchanged, same as before this task existed. *)
exception Sender_mismatch of string

(* Every message type's claimed sender, cross-checked against [~sender] -- the
   transport-authenticated identity of whoever actually holds the connection these [bytes] arrived
   on (Task 1's [Transport_intf.S.receive : t -> string * int], threaded through by every real
   caller; see cluster.ml's dispatch loop). [source] on [Prepare]/[Start_view] and [i] on
   [Prepare_ok]/[Start_view_change]/[Do_view_change] are otherwise just payload bytes an adversary
   who does NOT control the authenticated connection could still write -- so a mismatch here is
   proof the sender is lying about who it is, not routine protocol noise (an out-of-order [n], a
   stale [view]) the rest of this module already drops silently. Checked BEFORE any
   message-type-specific logic runs (mirroring [classify_append_refusal]'s own "guard failure before
   mutation" discipline), by raising {!Sender_mismatch} -- a genuinely different signal from every
   in-dispatch guard below, which stays a silent no-op: those guards reject well-attributed but
   protocol-stale messages (the normal, expected cost of an unreliable network), while THIS guard
   rejects a message whose very identity claim cannot be trusted, which callers should be able to
   observe/log/count as a security event rather than have it vanish the same way a merely-late
   Prepare does. See replica.mli's own doc comment on [handle_message] for the full rationale and
   {!Riptide_dst.Cluster}'s dispatch loop for how a caller stays total in the face of it.

   Once a message's claimed sender has passed this cross-check, [handle_prepare]/[handle_start_view]
   run a SECOND, independent check of their own (Finding 3): that the now-trusted [source] is
   actually entitled to send THIS message type at all -- i.e. is really Primary of the relevant view,
   not just some real, credentialed replica sending under its own true identity. Passing [source]
   (not [sender] -- the two are equal by construction past this point, but [source] is the name the
   message's own field carries and what those functions' own doc comments describe checking) lets
   each handler make that determination with exactly the information VSR.tla's own [IsNormalBackup]/
   [Primary] conjuncts require. *)
(* M2, audit-remediation Task 3 fix round: the cross-check itself used to be five independently
   typed-out [if <> then raise (Sender_mismatch (Printf.sprintf ...)) else ...] blocks, one per
   message-type branch below -- easy to drift (a future edit fixing a typo in one copy but not the
   other four) and, per the reviewer's own note, the real risk is a FUTURE sixth message type
   arriving here without anyone deciding what its sender field even is. [Message.claimed_sender]
   (message.mli) now owns that decision, with an exhaustive match that makes skipping a new
   constructor a compile error there, not a silently-missing branch here; this function is just the
   one place the check itself runs, parameterized by the two strings each branch's own error text
   needs. *)
let check_claimed_sender (msg : Message.t) ~(sender : int) ~(kind : string) ~(field : string) =
  let claimed = Message.claimed_sender msg in
  if claimed <> sender then
    raise
      (Sender_mismatch
         (Printf.sprintf "handle_message: %s claims %s %d but the transport-authenticated sender is %d" kind field
            claimed sender))

let handle_message t ~(sender : int) (bytes : string) =
  match Message.decode bytes with
  | exception Message.Malformed_message _ -> ()
  | Message.Prepare { view; n; v; k; source } as msg ->
    check_claimed_sender msg ~sender ~kind:"Prepare" ~field:"source";
    handle_prepare t ~view ~n ~v ~k ~source
  | Message.Prepare_ok { view; n; i } as msg ->
    check_claimed_sender msg ~sender ~kind:"PrepareOk" ~field:"i";
    handle_prepare_ok t ~view ~n ~i
  | Message.Start_view_change { v; i } as msg ->
    check_claimed_sender msg ~sender ~kind:"StartViewChange" ~field:"i";
    handle_start_view_change t ~v ~i
  | Message.Do_view_change { v; entries; nacks; last_normal_view; n; k; i } as msg ->
    check_claimed_sender msg ~sender ~kind:"DoViewChange" ~field:"i";
    handle_do_view_change t ~v ~entries ~nacks ~last_normal_view ~n ~k ~i
  | Message.Start_view { v; log; n; k; source } as msg ->
    check_claimed_sender msg ~sender ~kind:"StartView" ~field:"source";
    handle_start_view t ~v ~log ~n ~k ~source

(* ---- Test-support surface (continued): read-only views of the two view-change accumulators ----
   [recv_dvc]/[recv_svc] are private, and the protocol itself never needs to expose them -- but
   several properties this module is REQUIRED to hold are stated directly about them and are
   otherwise only observable indirectly, through whether a message eventually gets sent:
   [ReceiveSV]'s deliberate NON-reset of both (VSR.tla:304), the per-episode reset performed by
   [check_timeout]/[ReceiveHigherSVC] (VSR.tla:169, 190), and [recv_dvc]'s sender-keyed first-wins
   dedup. Both return sorted sender ids so a test can assert on an exact list. *)
let for_test_recv_dvc_senders t = Hashtbl.fold (fun i _ acc -> i :: acc) t.recv_dvc [] |> List.sort compare
let for_test_recv_svc_senders t = Int_set.elements t.recv_svc

(* The pure-discard entry point into [truncate_wal] -- see that function's own comment for the
   [~resulting_length] argument this passes and why. Test-support, not protocol: no VSR action
   truncates the WAL without writing the canonical log back in the same step, so this is the only
   caller for which the guard reduces to the plain "op_number >= commit_number" form the plan's
   Review Focus item states. *)
let for_test_truncate_wal t ~op_number =
  truncate_wal t ~op_number ~committed:t.commit_number ~resulting_length:op_number;
  if op_number < t.op_number then begin
    t.op_number <- op_number;
    Replica_log.replace_with t.log
      (List.filteri (fun idx _ -> idx < op_number) (Replica_log.to_list t.log));
    persist_superblock t
  end

let for_test_wal_read t ~op_number =
  match slot_state t ~op_number with Present v -> Some v | Corrupt | Absent -> None

(* I2, promoted to a real accessor by subtask 3.7: how many durable appends this replica has had
   refused, per refusal shape (see [append_refusal]'s own comment for what each one means and why
   flattening them into one "not durable" was the finding). Returned as (name, count) pairs in a
   fixed order so a caller can assert on exact values or track one name's growth over time.

   Renamed from [for_test_append_refusals] rather than shadowed by a second accessor: subtask 3.7's
   own consumer is production code watching [eviction_blocked] climb, so a [for_test_] prefix would
   now be actively false, and keeping both names would leave the misleading one as the obvious thing
   to reach for. Still NOT protocol -- nothing in this module reads it, and the counts influence no
   decision here; see replica.mli for the intended real use. *)
let append_refusals t =
  List.map (fun r -> (append_refusal_name r, t.append_refusals.(append_refusal_index r)))
    append_refusal_kinds
