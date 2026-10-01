open Riptide

type write = {
  actor : Envelope.actor_id;
  causation : Envelope.event_id;
  correlation : Envelope.event_id;
  payload : Value.value;
  merge_key : string option;
}

(* ---- write <-> Value.value ----

   Mirrors Envelope.to_value's own field-encoding convention exactly (String for actor, Bytes for
   hash-typed fields) -- see lib/envelope.ml. Field LOOKUP on decode is by name (List.assoc_opt),
   never by list position: a value that went through Value.canonical_encode/decode (e.g. arrived
   over the wire, on a backup) has its Record fields canonically re-sorted alphabetically by key
   (lib/value.ml), but a value this same process proposed locally and is now reading back via
   Replica.entries never took that round-trip -- the two can have DIFFERENT in-memory field
   orders for the exact same logical batch. *)

(* merge_key <-> Value.value: a Sum-tagged encoding, the same tagging convention
   lib/vsr/message.ml already uses for its own variant wire shapes ("none"/"some" rather than a
   native Option case, since Value.value has none). *)
let merge_key_to_value = function
  | None -> Value.Sum ("none", Value.Record [])
  | Some k -> Value.Sum ("some", Value.Scalar (Value.String k))

let write_to_value (w : write) : Value.value =
  Value.Record
    [
      ("actor", Value.Scalar (Value.String w.actor));
      ("causation", Value.Scalar (Value.Bytes w.causation));
      ("correlation", Value.Scalar (Value.Bytes w.correlation));
      ("payload", w.payload);
      ("merge_key", merge_key_to_value w.merge_key);
    ]

let field_opt fields name = List.assoc_opt name fields

(* [None] (missing field entirely) is backward-compatible with every batch committed before this
   field existed -- decodes as [Some None], i.e. a well-formed write with no merge_key, exactly as
   if it had been proposed with [merge_key = None] all along. A field that IS present but not
   shaped like [merge_key_to_value]'s own encoding is a genuinely malformed write, same discipline
   as actor/causation/correlation/payload below: [None] here voids the whole write. *)
let merge_key_of_field = function
  | None -> Some None
  | Some (Value.Sum ("none", Value.Record [])) -> Some None
  | Some (Value.Sum ("some", Value.Scalar (Value.String k))) -> Some (Some k)
  | Some _ -> None

(* causation/correlation are Envelope.event_id = Value.hash, documented in lib/value.mli as "Raw
   32-byte SHA-256 digest" -- Value.hash_to_hex raises Invalid_argument on anything else. A
   committed entry is arbitrary VSR-replicated bytes with no payload-integrity guarantee (this
   codebase's own established threat model), so a wrong-length causation/correlation must make
   the WHOLE write fail to decode here, exactly like every other malformed-write case, rather than
   producing a well-typed write/envelope whose fields silently violate their own documented
   contract. *)
let write_of_value (v : Value.value) : write option =
  match v with
  | Value.Record fields -> (
    match
      ( field_opt fields "actor",
        field_opt fields "causation",
        field_opt fields "correlation",
        field_opt fields "payload",
        merge_key_of_field (field_opt fields "merge_key") )
    with
    | Some (Value.Scalar (Value.String actor)), Some (Value.Scalar (Value.Bytes causation)),
      Some (Value.Scalar (Value.Bytes correlation)), Some payload, Some merge_key
      when String.length causation = 32 && String.length correlation = 32 ->
      Some { actor; causation; correlation; payload; merge_key }
    | _ -> None)
  | _ -> None

(* ---- batch <-> Value.value ---- *)

let batch_to_value ~(idempotency_key : string) (writes : write list) : Value.value =
  Value.Record
    [
      ("idempotency_key", Value.Scalar (Value.String idempotency_key));
      ("writes", Value.Sequence (List.map write_to_value writes));
    ]

(* [None] if EITHER the outer shape is wrong OR any single write inside it fails to decode -- a
   batch with one malformed write is a malformed batch as a whole, never a partial batch. *)
let batch_of_value (v : Value.value) : (string * write list) option =
  match v with
  | Value.Record fields -> (
    match (field_opt fields "idempotency_key", field_opt fields "writes") with
    | Some (Value.Scalar (Value.String idempotency_key)), Some (Value.Sequence write_values) ->
      let decoded = List.map write_of_value write_values in
      if List.for_all Option.is_some decoded then Some (idempotency_key, List.filter_map Fun.id decoded)
      else None
    | _ -> None)
  | _ -> None

(* ---- read side ---- *)

let committed_batch_values (t : Riptide_vsr.Replica.t) : Value.value list =
  let all = Riptide_vsr.Replica.entries t in
  let committed_count = Riptide_vsr.Replica.commit_number t in
  List.filteri (fun i _ -> i < committed_count) all

let has_key ~(idempotency_key : string) (v : Value.value) : bool =
  match batch_of_value v with Some (key, _) -> String.equal key idempotency_key | None -> false

(* The writes of the batch that actually COMMITTED under [idempotency_key], decoded from the
   committed bytes themselves -- [None] if no well-formed committed batch carries that key.

   First-wins per key, deliberately identical to [committed_envelopes_keyed]'s own dedup rule (a
   malformed batch never claims a key, since it contributes no envelopes to skip in favour of), so
   the writes this returns are exactly the writes whose envelopes that function publishes. That
   agreement is the point of this function; see [propose]'s own materialize step for the defect
   its absence caused. *)
let committed_writes_for (t : Riptide_vsr.Replica.t) ~(idempotency_key : string) : write list option =
  let rec find = function
    | [] -> None
    | v :: rest -> (
      match batch_of_value v with
      | Some (key, writes) when String.equal key idempotency_key -> Some writes
      | _ -> find rest)
  in
  find (committed_batch_values t)

(* The membership question [committed_writes_for] above answers over the committed prefix, asked
   over the WHOLE log instead -- i.e. "has a batch under this idempotency key ever been APPENDED
   here", committed or not. Uses [Replica.entries] directly (the raw log, including the
   replicated-but-not-yet-agreed tail) rather than [committed_batch_values].

   Why this exists, and why [propose] gates on it rather than on [already_committed] (review
   finding, 2026-09-23 -- a real fault-free data-destruction path, not a hypothetical one): in any
   real [replica_count >= 3] cluster [Riptide_vsr.Replica.propose] never commits synchronously, so
   there is a genuine window in which a batch is appended to the log but [already_committed] is
   still false. A client retry inside that window is not a fault -- this layer provides no
   acknowledgment mechanism at all (see batch_commit.mli's own [propose]), so it is the ONLY kind
   of retry a client can issue, and it is expected.

   Unencrypted, such a retry is harmless: [Riptide_vsr.Replica.propose]'s own duplicate-value
   suppression ([List.exists (value_equal ...) (entries t)], replica.ml) sees a byte-identical
   value and does nothing. ENCRYPTION DEFEATS THAT SUPPRESSION: encrypting mints a fresh DEK and a
   fresh nonce, so the retry's batch value is byte-DIFFERENT, [value_equal] never matches, and a
   SECOND entry is appended -- while the keystore [put] for the same derived event_id has already
   overwritten the first entry's DEK in place. Both entries then commit;
   [committed_envelopes_keyed] keeps the first (first-wins per key), whose ciphertext the surviving
   DEK cannot open. The record is permanently unrecoverable, with no fault injected and the hash
   chain still verifying -- nothing surfaces the loss.

   Gating on log membership instead closes that window: a key already present ANYWHERE in the log
   is never re-encrypted and never re-proposed. This deliberately does not change
   [Riptide_vsr.Replica.propose]'s own [value_equal] suppression, which still covers the
   unencrypted identical-retry case exactly as before. *)
let already_in_log (t : Riptide_vsr.Replica.t) ~(idempotency_key : string) : bool =
  List.exists (has_key ~idempotency_key) (Riptide_vsr.Replica.entries t)

type materialize_sink = { write : merge_key:string -> Value.value -> unit }
type encryption_sink = { encrypt : event_id:string -> Value.value -> Value.value }

(* Universal authorization checkpoint (task-master Task 5, subtask 5) -- see batch_commit.mli's
   own [decision]/[allow_all]/[authorization_denials]/[create]/[propose] doc comments for the full
   contract. [decision] is deliberately NOT [bool]: a [Deny] carries a human-readable reason for
   logs/debugging, matching this codebase's own established preference (see
   [Riptide_materialize.Materializer.Value_too_large] and [Riptide_vsr.Replica]'s own
   [append_refusals] reason strings) for a diagnosable failure shape over a bare boolean, even
   though nothing in this module parses or compares the reason itself -- a denied batch is
   refused in full, so the reason never reaches the replicated log. *)
type decision =
  | Allow
  | Deny of string

let allow_all (_ : write) : decision = Allow

(* Shaped exactly like [materialize_write_failures_count] below (and, before it,
   [Riptide_vsr.Replica.append_refusals]): a single, process-lifetime, monotonically-increasing
   counter, never reset. See batch_commit.mli's own [authorization_denials] doc comment. *)
let authorization_denials_count = ref 0
let authorization_denials () = !authorization_denials_count

(* Construction-time authorize/require_encryption policy (task-master Task 5, subtask 5;
   task-master subtask 5.3, audit-remediation design spec Decision 5.3) -- see batch_commit.mli's
   own [t]/[create]/[replica] doc comments for the full rationale. Only [propose] consumes either
   field; every other function in this module keeps taking a bare [Riptide_vsr.Replica.t]
   directly, so this type exists purely to give [propose] somewhere to read deployment-wide policy
   from. *)
type t = {
  replica : Riptide_vsr.Replica.t;
  authorize : write -> decision;
  (* Layer 0/Layer 2 boundary revision (task-master Task 7, this task's own brief), closing the
     Known, disclosed residual gap batch_commit.mli's own [create] doc comment names: [authorize]
     above sees ONE write at a time, with no visibility into any sibling write in the same batch, so
     no cross-write invariant (e.g. a double-entry ledger's "these two legs are a matched, balancing
     pair, both present in this batch") could ever be enforced by this module's checkpoint at all.
     [authorize_batch] is that batch-aware extension: evaluated once per batch, given the WHOLE
     [writes] list, under the exact same guard [authorize] above is evaluated under (see [propose]
     below) -- not a separate check with its own, possibly-divergent gating. [fun _ -> Allow] (the
     default every existing call site gets for free, unlike [authorize] itself, which has no
     default) preserves exactly today's behaviour: no batch-level policy, per-write enforcement
     only. *)
  authorize_batch : write list -> decision;
  require_encryption : bool;
  (* Layer 0/Layer 2 boundary revision (task-master Task 7), closing Task 6's own boundary
     friction item 1 (final whole-branch review finding I9): a durable, per-(idempotency_key,
     position) watermark that {!materialize_write_catching} below consults BEFORE calling
     [sink.write] and records strictly AFTER it returns successfully, making the repeated-
     materialize idiom (the empty-[writes] drain in [propose], and any overlapping
     [materialize_up_to] range) exactly-once for a sink of ANY shape -- including a
     non-idempotent, accumulating one -- not merely safe for a pure lattice join. [None]
     (the default) preserves today's behaviour exactly: no watermark is consulted or recorded,
     so a repeated materialize re-applies every time, same as before this field existed. *)
  materialize_watermark_store : Riptide_storage.File_kv_store.t option;
}

let create ~replica ~authorize ?(authorize_batch = fun (_ : write list) -> Allow) ?(require_encryption = false)
    ?materialize_watermark_store () =
  { replica; authorize; authorize_batch; require_encryption; materialize_watermark_store }

let replica (t : t) = t.replica

(* Layer 0/Layer 2 boundary revision (task-master Task 7, this task's own brief; spec Decision 5) --
   see batch_commit.mli's own [is_primary] doc comment for the full contract and its disclosed
   residual gap. Exactly the compound condition [propose]'s own existing silent-no-op guard already
   checks internally (see [Riptide_vsr.Replica.propose]'s own doc comment), exposed here as the one
   predicate a Layer 2 caller actually needs rather than something it has to independently discover
   and reproduce. *)
let is_primary (t : t) : bool =
  Riptide_vsr.Replica.is_primary t.replica && Riptide_vsr.Replica.status t.replica = Riptide_vsr.Replica.Normal

(* The synthetic write [propose] appends to a batch it actually proposes, once every one of the
   batch's real writes is [Allow]ed -- see batch_commit.mli's own [propose] "Authorization"
   section. A plain Record, the same encoding style every other payload in this codebase's test
   suite and this module's own doc examples use: [idempotency_key] so the decision is
   self-describing without needing to be paired with its batch by position, and [decision] so the
   shape has room for a future non-binary policy outcome without a wire-format change, even though
   today it is always ["allow"] (a [Deny] never reaches this function -- see [propose] below). *)
let authorization_decision_payload ~(idempotency_key : string) : Value.value =
  Value.Record
    [
      ("idempotency_key", Value.Scalar (Value.String idempotency_key));
      ("decision", Value.Scalar (Value.String "allow"));
    ]

(* ---- per-write materialize failure counting (task-master audit-remediation Task 21) ----

   {!Riptide_materialize.Materializer.write} can raise {!Riptide_materialize.Materializer.Value_too_large}
   when the joined accumulator's encoded size exceeds the KV backend's own [max_value_size] -- see
   that function's own WARNING in materializer.mli for the full, deliberately-unfixed account
   (unbounded accumulator growth vs. a bounded KV value size; NOT relitigated here). Before this
   counter and {!materialize_write_catching} existed, that exception (then a bare [Invalid_argument]
   -- {!Riptide_materialize.Materializer.Value_too_large} was introduced by this same task's review
   fix round specifically so this catch could stop being a blanket [Invalid_argument], see
   {!materialize_write_catching}'s own comment below) propagated straight out of whichever loop
   invoked [write] -- [propose]'s own single-batch fold, or [materialize_up_to]'s replay walk --
   aborting every OTHER write still queued in that loop, not just the one that actually overflowed.

   This counter lives HERE, in Batch_commit, deliberately not as a field on
   {!Riptide_vsr.Replica.t} the way [append_refusals] lives there (see that function's own doc
   comment in replica.mli for the shape this one intentionally mirrors): a materializer write
   failure is a downstream KV-value-size limit on the MATERIALIZATION side, nothing to do with
   consensus durability, and [Batch_commit] sits ABOVE [Replica] and consumes it -- coupling the
   lower module to a fact about the layer built on top of it would be exactly backwards. It is a
   single, process-lifetime counter rather than one per [Replica.t] or per [t]. When this was
   written (Task 21) the reason given was that there was no [Batch_commit.t] at all to attach one
   to -- that reason EXPIRED: Task 27 introduced [t] (see [create] below) six tasks later, and this
   comment kept asserting its absence (final whole-branch review, finding I3). The decision stands
   on its own footing regardless: [t] carries deployment POLICY ([require_encryption]) and is
   consulted by [propose] alone, while [materialize_up_to]'s replay walk -- the other loop that
   drives [materialize_write_catching] and therefore this counter -- still takes a bare
   [Riptide_vsr.Replica.t] and has no [t] in scope to read or write a per-handle counter through.
   Attaching the counter to [t] would make the two loops' failures unaggregatable, which is the one
   thing {!materialize_write_failures}' own contract promises they are not. Like [append_refusals],
   it never resets: the useful reading is a delta between two samples taken around a call of
   interest, not an absolute value read in isolation. *)
let materialize_write_failures_count = ref 0

let materialize_write_failures () = !materialize_write_failures_count

(* The keystore key for one write, derived from data available BEFORE the write enters the
   replicated log -- which is the only moment encryption can happen, since Envelope.content_hash
   covers the payload (lib/envelope.ml's to_value) and is therefore already committed to whatever
   bytes the log holds. The envelope's own event_id (= its content_hash) is unusable here: it also
   covers predecessor_hash and sequence, which only exist once the write's position in the
   committed log is settled, i.e. strictly after the payload had to be final. See
   batch_commit.mli's [redaction_event_id] and Riptide_crypto.Redaction_store's own header.

   Length-prefixing the idempotency key makes the derivation injective by construction rather than
   by argument: ("a", 1) and ("a#1", 0) produce "1:a#1" and "3:a#1#0", which cannot collide for
   any pair of inputs, whatever characters an opaque caller-supplied idempotency key contains.

   Moved ABOVE {!materialize_write_catching} (previously defined only just above {!propose},
   further down this file) so the watermark mechanism below can reuse it directly -- OCaml has no
   forward references across top-level [let]s, and the watermark's own key derivation must be this
   exact function, not a second, hand-rolled scheme (see {!materialize_write_catching}'s own doc
   comment for why). *)
let redaction_event_id ~idempotency_key ~index =
  Printf.sprintf "%d:%s#%d" (String.length idempotency_key) idempotency_key index

(* Catches ONLY {!Riptide_materialize.Materializer.Value_too_large} -- and NOT a blanket
   [Invalid_argument] -- matching this codebase's own established discipline for narrow,
   documented-shape catches elsewhere: see {!Riptide_vsr.Replica.durable_append}'s own
   [Storage_fault] classification in lib/vsr/replica.ml for the STYLE precedent (catch exactly the
   documented shape, count it, and let anything else propagate as a genuine contract violation
   rather than laundering it into "safe to skip").

   Review fix (this task's own review, round 1): the FIRST cut of this helper caught a blanket
   [Invalid_argument], which is wider than intended -- [sink.write] for a real [Materializer.t]
   runs [Materializer.write]'s WHOLE body (decode, [L.join], AND [encode]), not just the final
   [KV.put] size-cap check, and a caller's own [encode] (e.g.
   {!Riptide.Value.canonical_encode}'s own documented duplicate-Record/Map-key rejection) can raise
   an UNRELATED [Invalid_argument] that is a genuine value-layer bug, not the size cap. Catching
   every [Invalid_argument] here would have silently absorbed and miscounted that as "the
   documented size cap" the moment a real caller or a Map-merging lattice used this path (latent
   today only because the one lattice this repo ships, [Last_write_wins], has a trivial scalar
   encode that cannot hit it). {!Riptide_materialize.Materializer.write} now raises the narrowly
   distinct {!Riptide_materialize.Materializer.Value_too_large} for exactly the size-cap case
   (wrapped tightly around just its own [KV.put] call -- see that exception's own doc comment), so
   catching that ONE exception type here, instead of any [Invalid_argument], is what actually
   restores the "an unrecognized exception shape propagates as a contract violation" guarantee for
   this call site specifically.

   Shared by BOTH [propose]'s materialize step and [materialize_up_to]'s replay loop, so the two
   loops cannot drift into different catch behaviour -- exactly the "one shared helper" this task
   requires rather than duplicating the same try/with twice.

   [?watermark_store] (Task 7, closing Task 6's own boundary friction item 1): when supplied,
   makes a replay of this exact [(idempotency_key, position)] write exactly-once regardless of
   what [sink.write] itself does -- a watermark already present for
   [redaction_event_id ~idempotency_key ~index:position] (the same injective key-derivation
   {!propose}'s own [?encryption] path already uses, reused here rather than inventing a second,
   delimiter-joined scheme -- see that function's own doc comment for why a hand-joined key would
   not be injective) short-circuits straight to [()] without ever calling [sink.write] again. The
   watermark is recorded ONLY strictly after [sink.write] returns normally: a write that raises
   {!Riptide_materialize.Materializer.Value_too_large} did not successfully apply, so recording a
   watermark for it would permanently and wrongly mark it as done, skipping it forever on every
   later replay instead of leaving it eligible to be retried (e.g. against a KV backend with a
   larger size bound). [None] (the default both call sites pass when their own [t]/call-site
   argument supplies no store) skips the watermark check and record entirely, preserving exactly
   today's behaviour: safe only for an idempotent sink, unconditionally re-applied on every
   replay. *)
let materialize_write_catching (sink : materialize_sink) ?(watermark_store : Riptide_storage.File_kv_store.t option)
    ~(idempotency_key : string) ~(position : int) ~(merge_key : string) (payload : Value.value) : unit =
  let watermark_key () = redaction_event_id ~idempotency_key ~index:position in
  let already_applied =
    match watermark_store with
    | None -> false
    | Some store -> Option.is_some (Riptide_storage.File_kv_store.get store ~key:(watermark_key ()))
  in
  if already_applied then ()
  else
    match sink.write ~merge_key payload with
    | () -> (
      match watermark_store with
      | None -> ()
      | Some store -> Riptide_storage.File_kv_store.put store ~key:(watermark_key ()) "1")
    | exception Riptide_materialize.Materializer.Value_too_large _ -> incr materialize_write_failures_count

(* Range-based generalization of [committed_writes_for]/[propose]'s own single-key materialize
   step: walks the committed prefix up to [through_commit_number] (not just the one batch
   claiming a particular idempotency_key), materializing every write carrying a [merge_key] along
   the way, first-wins per idempotency_key (the same dedup rule [committed_envelopes_keyed] below
   already uses -- a batch here must never win out over the SAME [committed_writes_for] a caller
   sharing this key via [propose] would see). See batch_commit.mli for the full contract
   (idempotent, restart-safe, no own watermark state, O(through_commit_number) per call).

   [through_commit_number] is clamped against [Riptide_vsr.Replica.commit_number t] BEFORE it is
   used as a walk bound, exactly like [committed_batch_values] above already clamps its own walk
   -- never trust the caller-supplied bound alone. [Replica.entries] includes the
   replicated-but-not-yet-committed tail (its own .mli says so explicitly), so an un-clamped walk
   would fold an uncommitted entry into the lattice accumulator on any caller-supplied bound at or
   past [commit_number] -- including a restart-recovered watermark, which [replica.mli]'s own
   restart guidance documents can land ahead of a freshly-restarted replica's [commit_number]. A
   lattice join can never undo that: a later view change can then discard the very log entry that
   was materialized (see [Replica_log.replace_with]), leaving permanently materialized data with
   no committed entry ever backing it -- the same class of "permanent, unauditable divergence a
   lattice join can never undo" this module's own [propose] doc comment already names for a
   different hazard.

   [?watermark_store] (Task 7, closing Task 6's own boundary friction item 1): threaded straight
   through to {!materialize_write_catching} for every write in the walk, keyed by each write's own
   [idempotency_key] and its 0-based position within its own batch (the same convention
   {!redaction_event_id} already establishes) -- making two calls over an overlapping range
   exactly-once per write regardless of [materialize]'s own idempotence, not merely safe for a
   pure lattice join. [None] (the default) preserves exactly today's behaviour.

   [@warning "-16"]: this signature's shape (an optional [?watermark_store] with no trailing
   [()], the labeled, required [~materialize]/[~through_commit_number] both lexically BEFORE it)
   is exactly what this task's own brief specifies for this function and the exported .mli type
   below. OCaml's warning 16 ("unerasable-optional-argument") fires on this shape purely from how
   the value binding itself is parsed, regardless of the .mli's own type constraining it -- see
   {!Riptide_module.Admission.verify}'s identical, already-precedented use of this same per-binding
   attribute for the identical shape. *)
let[@warning "-16"] materialize_up_to (t : Riptide_vsr.Replica.t) ~(materialize : materialize_sink)
    ~(through_commit_number : int) ?(watermark_store : Riptide_storage.File_kv_store.t option) : unit =
  let bound = min through_commit_number (Riptide_vsr.Replica.commit_number t) in
  let entries = Riptide_vsr.Replica.entries t in
  let seen_keys = Hashtbl.create 16 in
  List.iteri
    (fun i v ->
      if i < bound then
        match batch_of_value v with
        | None -> ()
        | Some (idempotency_key, writes) ->
          if Hashtbl.mem seen_keys idempotency_key then ()
          else begin
            Hashtbl.add seen_keys idempotency_key ();
            List.iteri
              (fun position (w : write) ->
                match w.merge_key with
                | None -> ()
                | Some merge_key ->
                  materialize_write_catching materialize ?watermark_store ~idempotency_key ~position ~merge_key
                    w.payload)
              writes
          end)
    entries

(* Task 6's own [?may_evict] predicate needs to answer "did the write at this op-number opt into
   materialization at all" without re-implementing batch_of_value's own decode logic a second time
   outside this module. Deliberately reads the WHOLE log via [Replica.entries] -- including the
   replicated-but-not-yet-committed tail -- not just the committed prefix: refusing to evict an
   entry that may yet commit is the safe direction for [?may_evict] to err in, so an
   appended-but-uncommitted [merge_key] write must answer [true] here, same as a committed one.
   [entries] is 0-based by list position; op-number N is at list index N - 1 (matching
   committed_batch_values' own established i <-> op-number correspondence used throughout this
   file). Returns false for an op-number outside the log's current bounds or a malformed batch --
   both cases mean nothing here is claiming a merge_key, which is the same as "never opted in" as
   far as [?may_evict] cares. *)
let write_at_op_number_has_merge_key (t : Riptide_vsr.Replica.t) ~(op_number : int) : bool =
  (* [op_number < 1] must be excluded BEFORE reaching [List.nth_opt]: unlike a too-large index
     (which [List.nth_opt] itself turns into [None]), a NEGATIVE index makes [List.nth_opt] raise
     [Invalid_argument] rather than return [None] (confirmed live: this was a real crash, not a
     hypothetical, caught by this function's own test for [op_number = 0] and a negative
     op_number). [op_number = 0] is never valid either way (op-numbers are 1-based), so both cases
     fold into the same early [false]. *)
  if op_number < 1 then false
  else
    match List.nth_opt (Riptide_vsr.Replica.entries t) (op_number - 1) with
    | None -> false
    | Some v -> (
      match batch_of_value v with
      | None -> false
      | Some (_idempotency_key, writes) -> List.exists (fun (w : write) -> Option.is_some w.merge_key) writes)

let propose (t : t) ~(idempotency_key : string) ?(require_encryption : bool option)
    ?(materialize : materialize_sink option) ?(encryption : encryption_sink option) (writes : write list) : unit =
  let replica = t.replica in
  (* The EFFECTIVE policy for this one call: a supplied ~require_encryption overrides [t]'s own
     stored policy (an unusual, deliberate per-call exception remains possible); omitted, [t]'s own
     policy -- set once, centrally, at {!create} time -- applies. See batch_commit.mli's own
     [propose] doc comment for why this moved off a bare per-call flag (task-master subtask 5.3,
     audit-remediation design spec Decision 5.3): a per-call flag alone sits at the exact same call
     site as ~encryption itself, so a call site careless enough to forget one was equally likely to
     forget the other. *)
  let require_encryption = Option.value require_encryption ~default:t.require_encryption in
  (* Deployment-level policy: a deployment that wants to enforce "every write through this path
     must be encrypted" previously had no way to say so -- ~encryption was purely opt-in per call,
     so an ordinary caller that simply forgot it produced a silent plaintext write with no error
     anywhere. This is checked FIRST, before the pre-existing merge_key+encryption rejection below,
     so a caller who somehow triggers both sees the more fundamental policy violation
     (require_encryption with no sink at all) rather than a check that presupposes a sink exists. *)
  if require_encryption && Option.is_none encryption then
    invalid_arg "Batch_commit.propose: require_encryption is true but no ~encryption sink was supplied";
  (* An EMPTY batch is never proposed -- not here, not in any log state (review finding,
     2026-09-23). This is a real data-destruction path, previously pinned as a known behaviour by
     test_batch_commit.ml's own [test_empty_batch_permanently_burns_its_key_via_propose] and now
     closed: an empty batch is perfectly well-formed, so [batch_of_value] decodes it, it claims
     [idempotency_key] in [committed_envelopes_keyed]'s own first-wins dedup set, and
     [already_in_log] below makes every LATER propose under that key a no-op. The key is poisoned
     permanently: a real batch proposed under it afterwards is never committed, never materialized,
     and nothing raises. What it buys in exchange is nothing at all -- an empty batch contributes
     zero envelopes and zero materialization -- so there is no state in which writing one is the
     right thing to do, and the guard is unconditional rather than "only when the key is new".

     Only the PROPOSE half is suppressed; the materialize step below still runs, because
     [propose t ~idempotency_key ~materialize:sink []] is this module's own documented way for a
     replica to drive its own committed batch into its own materializer (see batch_commit.mli),
     and that idiom must stay safe on a replica that has not yet learned of the batch -- a normal, expected
     state in any multi-replica cluster, not a caller error. Raising there instead would turn an
     ordinary replication lag into an exception.

     With NO [?materialize] either, the call can have no effect whatsoever -- nothing proposed,
     nothing materialized -- which is never what a caller meant, so that shape raises rather than
     silently doing nothing. *)
  (match (writes, materialize) with
  | [], None ->
    invalid_arg
      "Batch_commit.propose: an empty writes list with no ~materialize sink cannot do anything -- \
       an empty batch is never proposed (it would permanently claim this idempotency key while \
       contributing no envelopes, silently swallowing any later real batch under it), and with no \
       sink there is nothing to materialize either. Pass the batch's writes, or pass ~materialize \
       to drive an already-committed batch into a materializer."
  | _ -> ());
  (* Encrypted and materialized are mutually exclusive, and this fails loudly rather than
     silently: the materializer's accumulator holds joined plaintext, lives in its own KV store,
     and is structurally outside the redaction keystore -- so deleting a record's DEK would leave
     that record's contribution to the accumulator fully readable. A redaction that does not
     redact is worse than a rejected write. See batch_commit.mli for the full statement. *)
  (match encryption with
  | None -> ()
  | Some _ ->
    if List.exists (fun (w : write) -> Option.is_some w.merge_key) writes then
      invalid_arg
        "Batch_commit.propose: a write with merge_key = Some _ cannot also be encrypted \
         (~encryption): the materialized accumulator is outside the redaction keystore, so \
         deleting the DEK would not erase it");
  if writes <> [] && not (already_in_log replica ~idempotency_key) then begin
    (* Universal authorization checkpoint (task-master Task 5, subtask 5) -- see batch_commit.mli's
       own [propose] "Authorization" section for the full contract. Evaluated for EVERY write in
       [writes], HERE, inside the "this key is not already anywhere in the log" guard, and not a
       line earlier: this is deliberately the ONLY shape of [propose] call that could ever cause
       NEW data to enter the replicated log (review finding, this task's own review round 1). A
       call against a key already in the log -- whether [writes = []] (the documented drain idiom)
       or [writes] repeats the batch's own original content (the only kind of retry this
       fire-and-forget layer's own contract permits a client to issue) -- proposes nothing either
       way, so gating it here would deny a caller's LOCAL materialize-only request over data the
       cluster already, durably agreed on before this call was ever made; it would not protect
       anything, since nothing new is entering the log for [~authorize] to have a say over. The
       same operational goal (catch a replica's own materializer up on an already-committed key)
       is also reachable via [~materialize] on an empty [writes] list and via
       {!materialize_up_to} -- see the .mli for the full three-idiom account, and why all three
       are equally exempt from this checkpoint by construction: {!materialize_up_to} takes a bare
       {!Riptide_vsr.Replica.t}, with no {!t}/[~authorize] in scope at all to consult. *)
    (* [authorize_batch] (task-master Task 7, this task's own brief) is evaluated under the exact
       same guard as the per-write [authorize] loop above -- not a separate, possibly-divergent
       check -- so it inherits that guard's own exemptions by construction: it is never consulted
       for the empty-[writes] drain idiom, nor for a retry of an already-logged key, for precisely
       the reasons the per-write checkpoint's own comment above already gives. Either hook denying
       refuses the WHOLE batch and increments [authorization_denials_count] exactly once, matching
       the per-write checkpoint's own once-per-batch counting discipline -- not once per denying
       hook. *)
    let denied =
      List.exists (fun (w : write) -> match t.authorize w with Deny _ -> true | Allow -> false) writes
      || match t.authorize_batch writes with Deny _ -> true | Allow -> false
    in
    if denied then incr authorization_denials_count
    else begin
      (* Encryption happens HERE, inside the "this key is not already anywhere in the log" guard,
         and not a line earlier: encrypting mints a fresh DEK and overwrites the keystore entry for
         this event_id. Doing that on a retry of a batch already in the log -- committed OR merely
         appended-and-awaiting-quorum -- would orphan the DEK for a ciphertext that is (or is about
         to become) immutably committed, permanently destroying a record nobody asked to redact.
         [already_in_log], not [already_committed], is the guard precisely because the
         appended-but-uncommitted window is the normal state of every multi-replica propose; see
         [already_in_log]'s own comment for the full failure mode this closes. *)
      let writes_with_encryption =
        match encryption with
        | None -> writes
        | Some sink ->
          List.mapi
            (fun index (w : write) ->
              { w with payload = sink.encrypt ~event_id:(redaction_event_id ~idempotency_key ~index) w.payload })
            writes
      in
      (* The authorization-decision write (batch_commit.mli's own [propose] "Authorization"
         section): appended LAST, after encryption, and never itself encrypted -- it records a
         fact ABOUT this batch's authorization, not user payload data, so it is deliberately
         outside the encrypted-payload/redaction story above. [causation]/[correlation] copied
         from [writes]'s own first element (available here: this whole block is reached only when
         [writes <> []]) make it a real, causally-linked member of the same atomic batch rather
         than a freestanding fact. *)
      let first_write = List.hd writes in
      let authorization_decision_write : write =
        {
          actor = "riptide.module.authz";
          causation = first_write.causation;
          correlation = first_write.correlation;
          payload = authorization_decision_payload ~idempotency_key;
          merge_key = None;
        }
      in
      let writes_to_propose = writes_with_encryption @ [ authorization_decision_write ] in
      Riptide_vsr.Replica.propose replica (batch_to_value ~idempotency_key writes_to_propose)
    end
  end;
  (* Deliberately NOT gated behind "did THIS call perform the durable commit" -- a batch
     committed by an earlier call (or by this call, in the degenerate replica_count = 1 case
     above) is materialized here just the same. This makes materialization safe to retry: if a
     process crashes between Replica.propose's durable commit and the materialize step below,
     the very next propose call for the SAME idempotency_key -- even though already_in_log
     above makes it skip re-proposing -- still reaches this point and re-attempts the
     materialize. Note the two guards are deliberately DIFFERENT questions and must stay so:
     re-proposing is gated on "is this key anywhere in the log at all" (see already_in_log), while
     materializing is gated on "is it COMMITTED", since materializing an entry that has not yet
     reached quorum would publish state the cluster has not agreed on. That re-attempt is safe because Materializer.write is a read-join-put over a
     lattice: joining the same value into an already-converged accumulator is a no-op by the
     lattice laws (idempotent), so re-materializing an already-materialized write changes
     nothing. See batch_commit.mli's own [propose] doc comment for the corrected, full account
     of this behavior.

     Also, deliberately NOT gated behind whether the propose block above was itself skipped by a
     [Deny] -- a denied batch never enters the log, so [committed_writes_for] below finds nothing
     under its key regardless, and this step is a natural no-op for it. Nothing here needs its own
     "was it denied" check: a genuinely new, denied batch and a genuinely new, never-proposed batch
     look identical to the read side, by construction. *)
  match materialize with
  | None -> ()
  | Some sink -> (
    (* Materialize the writes that are actually COMMITTED under this key, read back out of the
       committed bytes -- never the [writes] argument this call happened to be handed (Task 9's
       end-to-end adversarial proof, 2026-09-23; see that task's report and
       test_lattice_materialize_crypto_scenarios.ml).

       Why this is the root fix and not a hardening: the two halves of this module disagreed about
       what "the batch under key K" means. The READ half ([committed_envelopes_keyed]) says: the
       FIRST well-formed committed batch carrying K, every later one skipped. This write half used
       to say: whatever the most recent caller passed. Any difference between the two went straight
       into a durable lattice accumulator, and a lattice join can never take it back out.

       Two real consequences, both reproduced before the fix:

       - {b Permanent, unauditable divergence.} A client retry under an already-committed key
         carrying different writes (the only kind of retry this fire-and-forget layer permits a
         client to issue at all, and one the read half above explicitly defends against) folded a
         payload that appears in NO committed entry on ANY replica into one replica's accumulator.
         Two replicas driven from the same committed log then hold different accumulators forever
         -- the divergence is not something a later join repairs, because no other replica will
         ever see the value.
       - {b A redaction that does not redact.} [propose] rejects [merge_key] together with
         [~encryption] precisely because a materialized accumulator lives outside the redaction
         keystore. That guard is per-call, and this step read the caller's argument, so the two
         could be split across two calls sharing one idempotency key: call one commits the payload
         as ciphertext under [~encryption], call two (same key, no [~encryption], so nothing is
         re-proposed and the guard never fires) hands the PLAINTEXT to a [merge_key] write and this
         step folds it durably into the accumulator. [Redaction_store.redact] then genuinely
         destroys the ciphertext's recoverability while the plaintext stays readable on disk
         forever.

       Reading the committed bytes closes both structurally rather than case by case: a committed
       batch's own [merge_key]s and payloads are the only thing that can ever be materialized, so
       the accumulator is a function of the committed log plus each key's own size-bound write
       history -- {b not} of the committed log alone (task-master audit-remediation Task 21
       narrowed this claim; see [materialize_write_failures] below and batch_commit.mli's own
       corrected account for why: a write can be silently and PERMANENTLY skipped if
       {!Riptide_materialize.Materializer.write} raises [Value_too_large] for it, but that outcome
       is itself a deterministic function of the write's own payload and the KV backend's fixed
       size bound, never of timing or which replica evaluates it, so this is still the same input
       every replica agrees on) -- and an encrypted batch (whose committed writes all carry
       [merge_key = None], enforced by the guard above at the only moment encryption can happen)
       can contribute nothing to it no matter what a later caller passes.

       [None] here is exactly the "not committed on this replica (yet)" case the old
       [already_committed t = false] test covered before this function replaced it: nothing to
       materialize, try again on a later call. Note the consequence that makes this
       strictly more capable rather than merely safer: because the payloads come from the log
       rather than the argument, ANY replica holding the committed batch can materialize its own
       commit stream -- including with an empty [writes] list -- which is what lets each replica
       feed its own materializer and converge. *)
    match committed_writes_for replica ~idempotency_key with
    | None -> ()
    | Some committed_writes ->
      List.iteri
        (fun position (w : write) ->
          match w.merge_key with
          | None -> ()
          | Some merge_key ->
            materialize_write_catching sink ?watermark_store:t.materialize_watermark_store ~idempotency_key ~position
              ~merge_key w.payload)
        committed_writes)

let committed_envelopes_keyed (t : Riptide_vsr.Replica.t) : (string * Envelope.envelope) list =
  let seen_keys = Hashtbl.create 16 in
  let _final_sequence, _final_predecessor_hash, envelopes_rev =
    List.fold_left
      (fun (sequence, predecessor_hash, acc) batch_value ->
        match batch_of_value batch_value with
        | None -> (sequence, predecessor_hash, acc)
        | Some (idempotency_key, writes) ->
          if Hashtbl.mem seen_keys idempotency_key then (sequence, predecessor_hash, acc)
          else begin
            Hashtbl.add seen_keys idempotency_key ();
            let _final_index, folded =
              List.fold_left
                (fun (index, (sequence, predecessor_hash, acc)) (w : write) ->
                  let sequence = Int64.add sequence 1L in
                  let envelope : Envelope.envelope =
                    {
                      actor = w.actor;
                      causation = w.causation;
                      correlation = w.correlation;
                      predecessor_hash;
                      sequence;
                      payload = w.payload;
                    }
                  in
                  ( index + 1,
                    ( sequence,
                      Envelope.content_hash envelope,
                      (redaction_event_id ~idempotency_key ~index, envelope) :: acc ) ))
                (0, (sequence, predecessor_hash, acc))
                writes
            in
            folded
          end)
      (0L, Envelope.genesis_marker, [])
      (committed_batch_values t)
  in
  List.rev envelopes_rev

let committed_envelopes (t : Riptide_vsr.Replica.t) : Envelope.envelope list =
  List.map snd (committed_envelopes_keyed t)
