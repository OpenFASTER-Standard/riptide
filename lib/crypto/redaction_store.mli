(** The redaction keystore: envelope encryption (design spec Decision 4) for content-hashed
    writes, and the one operation that makes redaction possible -- {!redact}, which deletes a
    record's wrapped DEK and nothing else.

    {b The scheme.} Every record gets its own {b freshly generated, independent} {!Dek} -- never a
    key derived from the KEK via HKDF or anything similar. That is the entire point: Kubernetes'
    own KMS v2 derives per-object keys from a shared seed for performance and, as a direct
    consequence, cannot redact one object -- the only deletable thing is the seed, which would
    erase everything. The real crypto-shredding precedent (AWS/GCP envelope encryption, the
    EventStoreDB/Verraes "Throw Away the Key" pattern) uses a genuinely separate, independently
    stored DEK per redaction unit, because that is what makes "delete one key, lose exactly one
    record" possible at all.

    The payload travels with the log, encrypted. The wrapped DEK lives here, in a keystore keyed
    by [event_id] -- structurally {b outside} anything the envelope's own
    {!Riptide.Envelope.content_hash} covers. Redaction is therefore exactly one operation, on one
    keystore row, and the hash chain never changes and never even observes it.

    {b What [event_id] means here, and what it deliberately does not.} It is an opaque keystore
    key, supplied by whoever encrypts, and it is {b not} the encrypted record's own
    {!Riptide.Envelope.event_id}. It cannot be: an envelope's [event_id] is its
    {!Riptide.Envelope.content_hash}, which covers the ciphertext {e and} the [predecessor_hash]
    and [sequence] that only exist once the record's position in the committed log is settled --
    so it is not knowable at the moment encryption has to happen (strictly before the payload
    enters the log, since that hash covers the payload). {!Riptide_batch_commit.Batch_commit}
    resolves this by deriving a stable, collision-free key from the batch's own idempotency key and
    the write's index within it; see {!Riptide_batch_commit.Batch_commit.redaction_event_id}. Any
    other caller may key records however it likes, provided the key is unique per record and
    stable for that record's lifetime.

    {b Concurrency.} A [t] is as safe to share as the underlying
    {!Riptide_storage.File_kv_store.t} and no safer. Two concurrent {!encrypt_for_storage} calls
    for the {e same} [event_id] race in the keystore exactly as two concurrent [put]s would -- one
    DEK wins, and the ciphertext returned by the loser becomes undecryptable. Callers must not
    reuse an [event_id] for two different records.

    {b Task 25 update:} [t] now does hold one piece of mutable state of its own -- its [kek]
    field, switched in place by {!rotate_kek}. See {!rotate_kek}'s own doc for exactly what that
    means for a caller racing a rotation against an ordinary {!encrypt_for_storage}/{!decrypt}
    call. *)

type t

val owner_tag : string
(** [owner_tag] is [create]'s own required {!Riptide_storage.File_kv_store.owner} value,
    ["redaction-keystore"] -- the one fixed, project-wide-unique tag every real caller in this
    codebase passes as [~owner:owner_tag] to the {!Riptide_storage.File_kv_store.create} that
    builds the [kv] it later hands to [create] below. Exported so every call site references this
    constant instead of repeating the string literal (subtask 4.8; previously scattered across the
    codebase by convention alone, with nothing enforcing it -- see [create]'s own doc comment
    below for what closed that gap). *)

val create : kv:Riptide_storage.File_kv_store.t -> kek:Kek.t -> t
(** [create ~kv ~kek] builds a keystore over [kv], wrapping every DEK it stores under [kek].

    [kv] holds only wrapped DEKs -- material that is useless without [kek] -- so it does not itself
    need to be a secret store. It does need real, durable per-key deletion, which is precisely why
    Task 2 introduced {!Riptide_storage.Kv_store_intf.S} rather than reusing
    {!Riptide_storage.Storage_intf.S}'s bounded-ring WAL shape: a redaction that leaves the DEK
    recoverable on disk is not a redaction.

    {b [kv] must be this keystore's alone} -- a directory no other {!Riptide_storage.File_kv_store}
    consumer also writes to. That store's key space is flat and untyped (one file per key, named by
    the key's own hash), so a second consumer sharing the directory and choosing a key equal to one
    of this store's [event_id]s collides with it destructively. It is reachable in practice, not
    merely in principle: a {!Riptide_materialize.Materializer} is the other consumer this plan
    creates, its keys are caller-chosen [merge_key]s, and this store's own keys are the plain
    strings {!Riptide_batch_commit.Batch_commit.redaction_event_id} derives -- so one [merge_key]
    shaped like [\{length\}:\{idempotency_key\}#\{index\}] is all it takes.

    {b Subtask 4.6 gave {!Riptide_storage.File_kv_store.create} a real, construction-time guard
    against exactly this}: build the [kv] you pass here with [~owner:owner_tag], and a second,
    differently-tagged {!Riptide_storage.File_kv_store.create} aimed at the same directory now
    raises [Invalid_argument] immediately, before either consumer can touch the shared directory's
    data at all -- turning the three silent outcomes below into a loud rejection at construction
    {e for that differently-tagged pair}, and only for it (see the residual gap below, which is
    real and still open).

    {b Subtask 4.8 closes one gap the 4.6 guard left open}: [create] above used to receive an
    already-built [kv] on faith -- there was no [File_kv_store.create] call inside this module for
    an owner tag to attach to, so the 4.6 guard only ever fired if the caller building [kv] had
    tagged it (then an optional argument), and nothing here could tell whether it had. [create] now
    checks {!Riptide_storage.File_kv_store.owner}[ kv] itself, closing that gap.

    @raise Invalid_argument if [kv]'s own owner (as {!Riptide_storage.File_kv_store.owner} reports
      it) is not [owner_tag] -- i.e. [kv] was built with a different [~owner] -- before this
      function returns a usable [t] and before either consumer can touch the shared directory's
      data.

    The other half of the same subtask does the identical thing to
    {!Riptide_materialize.Materializer.Make.create}, which now also checks its own [kv]'s owner
    against a caller-supplied [~owner] before constructing a usable [t], the same way this
    function does (see that function's own doc comment for its exact check, which mirrors this
    one).

    The same subtask (4.8, this branch's own work -- not a later, still-pending task) also made
    {!Riptide_storage.File_kv_store.create}'s [~owner] mandatory rather than optional, closing one
    further gap: previously, a SECOND consumer -- one that never goes through this function, e.g. a
    {!Riptide_materialize.Materializer} built directly over the same [dir_path] -- could point its
    own {!Riptide_storage.File_kv_store.create} at the shared directory without passing [~owner]
    at all, and that omission alone was enough to defeat the guard regardless of how carefully
    this side was tagged. That state is no longer constructible: any [File_kv_store.create], from
    any consumer, requires a real owner tag, and a directory can no longer be pointed at without
    one.

    {b A REAL, STILL-OPEN RESIDUAL GAP, stated plainly rather than claimed closed -- narrowed by
    Task 11, not eliminated.} Every check described above catches only a MISMATCHED tag. Two
    consumers sharing one directory under the SAME owner tag -- this keystore and a
    {!Riptide_materialize.Materializer} both built with [~owner:owner_tag], whether through
    copy-paste, a refactor, or a caller talked into agreeing on one tag -- pass every TAG-based
    check this codebase performs: the marker file matches, so each consumer's own
    construction-time owner check ([create] above, and
    {!Riptide_materialize.Materializer.Make.create}) sees the tag it expects.

    {b What Task 11 changed:} {!Riptide_storage.File_kv_store.create} now also takes a real,
    OS-level {!Riptide_storage.Dir_lock} (a [flock(2)]) on the directory, strictly before the
    marker check, and holds it for as long as the resulting [t] stays alive. If two SEPARATE
    [File_kv_store.create] calls over the same directory are ever SIMULTANEOUSLY live -- two
    independently-opened [t]s, whichever tags they pass -- the second one now raises
    [Invalid_argument] from the lock itself, before the marker is ever consulted. That closes
    double construction of two separate handles over one directory, for real, not merely for the
    mismatched-tag case the marker alone could already catch.

    {b What is still open, stated precisely (review finding I2, 2026-09-29 -- an earlier version of
    this disclosure narrowed the remaining gap to "strictly sequential reuse" only, which overclaims
    what the lock reaches: falsified live by a test that shares one already-built [kv] between this
    keystore and a materializer and still silently destroys a wrapped DEK, with the lock never once
    firing for that pairing, since {e no two} [File_kv_store.create] calls are ever CONCURRENT
    against it -- the sequential-reuse phases each do call [File_kv_store.create] afresh, one after
    the previous handle's switch has fully closed, so "only one call is ever made" would itself be a
    false claim about this same test; what actually defeats the lock is that no two of those calls
    ever overlap in time, which is a different, narrower property than "there is only one call"):}
    two different shapes, neither of which a lock scoped to one [create] call's own [t] can see:

    - {b Strictly SEQUENTIAL reuse}: one consumer's [t] fully released (its switch finished, its
      lock dropped) before the other's [create] runs. The marker cannot tell "my own store
      reopening" apart from "an unrelated consumer that happens to use my tag" once there is no live
      handle left to conflict with.
    - {b SIMULTANEOUS use of a single, ALREADY-CONSTRUCTED [kv] by two different logical
      consumers at once} -- [create] above takes [kv] on faith, exactly as stated at the top of
      this doc comment; if the SAME [kv] (one [File_kv_store.create] call, one lock, one marker
      check) is handed to both this keystore and a
      {!Riptide_materialize.Materializer.Make.create}, the lock never gets a second call to
      conflict with and the marker never gets a second tag to compare -- there is nothing for
      either guard to catch, no matter how carefully [kv] itself was constructed. That is exactly
      what "[kv] must be this keystore's alone", above, is asking a caller to guarantee by
      discipline, because neither guard can guarantee it mechanically.

    Both shapes destroy each other's data over one shared, flat key space exactly as silently and
    exactly as completely as before any of these guards existed -- so the three consequences below
    are still a live description of what such a pair does today, just no longer reachable through
    two INDEPENDENTLY-opened handles alive at once.

    This narrower gap is a disclosed, deliberately out-of-scope limitation of subtask 4.8 rather
    than an oversight (the design spec's own Non-Goals: "No change to the marker-file mechanism").
    Closing the sequential shape needs a different marker mechanism -- per-consumer key prefixes, or
    some persistent (not merely handle-lifetime-scoped) exclusivity record. Closing the shared-handle
    shape needs a guard neither this module nor {!Riptide_storage.File_kv_store} can provide at
    construction time at all, since by the time either [create] runs, [kv] already exists and
    neither function has any way to tell "the only consumer of this handle" from "one of several" --
    that is a caller-discipline requirement, not something construction-time code can enforce.

    Both shapes are backed by running code in [test/test_lattice_materialize_crypto_scenarios.ml]:
    the SEQUENTIAL shape in
    [test_using_the_same_owner_tag_on_both_sides_still_destroys_a_wrapped_dek]'s first two phases (a
    materializer's write, through its own, freshly-[create]d handle opened only after the phase-1
    keystore handle's switch has fully closed, silently destroys a record that now-closed handle
    wrote earlier -- pinning the FIRST consequence below), and the SHARED-HANDLE shape in that same
    test's third phase (one [kv], a keystore and a materializer both built directly from it at once,
    a keystore [put] silently overwriting the materializer's own accumulator value at a colliding
    key, with the lock never once firing because no second [create] call is made for either
    consumer -- pinning the THIRD consequence below). A DIFFERENT-tag pair, by contrast, is
    rejected at construction with this keystore's data provably intact
    ([test_a_shared_kv_directory_is_rejected_at_construction],
    restructured (review finding I3) so the colliding [create] attempt runs only after the first
    handle's lock has been released -- otherwise Task 11's own lock, not the owner-tag comparison
    this test exists to exercise, would be what raises, as an earlier version of this test did); that
    test demonstrates the ORIGINAL, still-fully-closed mismatched-tag gap, not either of the two
    shapes described here. The second consequence below is the same collision with a partial
    [decode] and is described here without a dedicated test of its own, since it differs only in the
    caller-supplied [decode] the first bullet already varies:

    - {b A materialized write onto an existing [event_id] destroys that record, silently}, if the
      materializer's own [decode] is total (returns its lattice's bottom for bytes it cannot parse
      -- a legitimate, even defensive choice, and [Materializer.create] neither requires nor
      forbids it). The accumulator's read-join-put simply overwrites the wrapped DEK; the record is
      then permanently unreadable, nothing raises anywhere, the accumulator looks healthy, the log
      and its hash chain are untouched, and the loss is indistinguishable from a deliberate
      {!redact} of that one record.
    - {b The same write raises instead, out of the materializer's caller's own [decode]}, if that
      [decode] is partial (the more common shape). Less bad -- the DEK survives, since the [put]
      never runs -- but it surfaces as an [Invalid_argument] from the materialize path about bytes
      no materializer ever wrote, and it recurs on every retry of that [merge_key] forever. Via
      {!Riptide_batch_commit.Batch_commit.propose} it raises AFTER the batch has committed, so it
      also diverges the accumulator from the log exactly the way
      {!Riptide_materialize.Materializer.Make.write}'s own size-bound WARNING describes.
    - {b In the other direction it is silent for ANY [decode]}: this store's own [put] never reads
      first, so encrypting a record whose derived [event_id] collides with an accumulator's
      existing [merge_key] overwrites that accumulator with wrapped-DEK bytes, with no error and no
      read. The record decrypts perfectly well afterwards; the accumulated lattice value is simply
      gone. *)

val encrypt_for_storage : t -> event_id:string -> Riptide.Value.value -> string
(** [encrypt_for_storage t ~event_id v] generates a fresh DEK, encrypts
    {!Riptide.Value.canonical_encode}[ v] under it, durably stores that DEK wrapped under the KEK
    (and bound to [event_id] as GCM additional authenticated data) at key [event_id], and returns
    the ciphertext.

    {b Ordering is deliberate and load-bearing}: the wrapped DEK is durably stored {e before} this
    function returns, hence before the caller can possibly write the returned ciphertext anywhere.
    The reverse order would make a crash in between permanently destroy a record nobody asked to
    redact. In this order a crash leaves at worst an orphan DEK for a ciphertext that was never
    written -- garbage, not data loss.

    Overwrites any DEK already stored at [event_id]. A caller that reuses an [event_id] for a
    second record therefore destroys the first; see this module's header on [event_id] uniqueness.

    {b Task 24: the stored record's VALUE is no longer just the wrapped-DEK bytes -- it is [event_id]
    itself (in the clear), length-prefixed, followed immediately by the wrapped DEK.} [event_id] is
    not made any less secret by this: it was already the plaintext GCM additional authenticated
    data {!Kek.wrap} takes, so it was never confidential to begin with (see this module's header).
    This closes a real, previously-open gap instead: {!Riptide_storage.File_kv_store} (the one real
    [kv] backend) hashes every KV key via SHA-256 before it ever touches disk, so the KV key
    [event_id] alone was never recoverable from what is actually on disk -- enumerating this
    keystore's contents required an external log of every [event_id] ever written. Embedding
    [event_id] in the value itself is what makes {!enumerate_event_ids} below possible with no such
    log. See {!Riptide_storage.Kv_store_intf.S.fold}'s own doc comment for the general shape of this
    problem (this store's keys are its own internal, hashed identifiers, never the original string a
    caller [put]), and this module's own [.ml] ([encode_record]/[decode_record]) for the exact,
    length-prefixed wire format this produces.

    {b No migration for records written before this format existed.} A pre-Task-24 wrapped-DEK
    record (raw {!Kek.wrap} output, no embedded [event_id] prefix) fails {!decrypt}'s internal
    decode of the new format and is therefore treated exactly like a genuinely redacted or corrupt
    entry -- observably indistinguishable from a real {!redact}, per {!decrypt}'s own documented
    "deliberately indistinguishable failures" contract. No migration was requested and none is
    performed; this is disclosed here only so a future reader is not surprised by an old-format
    record going silently unreadable after upgrading past this change, on a project that is
    pre-1.0 with no real deployed data to migrate. *)

val decrypt : t -> event_id:string -> string -> Riptide.Value.value option
(** [decrypt t ~event_id ciphertext] looks up [event_id]'s wrapped DEK, unwraps it under the KEK,
    and decrypts [ciphertext] with it.

    [None] -- never an exception -- for every failure, which are deliberately indistinguishable
    from one another: the record was redacted (no keystore entry), the keystore entry is corrupt or
    was tampered with, [event_id] is the wrong one for this ciphertext (the AAD binding rejects
    it), the KEK is the wrong one, the ciphertext was tampered with, or the recovered plaintext is
    not a well-formed {!Riptide.Value.canonical_encode} encoding. "Redacted" and "unrecoverable for
    some other reason" are the same observable outcome by design -- a caller learning which one it
    was would be learning something about a payload that is supposed to be gone.

    {b Task 24:} the keystore entry now also carries an embedded copy of its own [event_id] (see
    {!encrypt_for_storage}'s own doc comment), but this lookup path deliberately never trusts or
    even inspects it for its own correctness -- it always authenticates under the CALLER-SUPPLIED
    [event_id] (this function's own argument, i.e. the KV lookup key) as GCM AAD, exactly as before
    this task, and simply ignores the embedded copy. This is a considered choice, not an oversight:
    see [unwrap_dek_with] in this module's own [.ml] (Task 25: the function this logic now lives
    in, [unwrap_dek] itself having been folded into it once nothing but [decrypt_with] still needed
    a [t.kek]-defaulting wrapper) for why even a cheap plaintext cross-check against
    the embedded copy was deliberately rejected, not merely not added -- it would make the AAD-swap
    attack test_wrapped_dek_is_bound_to_its_event_id (test_redaction.ml) exercises fail for the
    wrong reason, masking rather than proving the real AAD-based protection. The embedded copy is
    read only by {!enumerate_event_ids} below, which has no security property riding on it. *)

val decrypt_with : t -> kek:Kek.t -> event_id:string -> string -> Riptide.Value.value option
(** [decrypt_with t ~kek ~event_id ciphertext] is {!decrypt}, except it authenticates and unwraps
    the stored DEK under the {b caller-supplied} [kek] instead of [t]'s own current key -- [t]
    itself is consulted only to reach the underlying keystore ([t]'s [kv]), never its own [kek].
    Indeed {!decrypt} is defined as nothing more than [decrypt_with t ~kek:t.kek ~event_id
    ciphertext].

    {b Task 25: this is the KEK-compromise recovery primitive, not optional polish.}
    {!rotate_kek} below can leave a real, on-disk mix after a crash partway through its own
    work -- some entries wrapped under the key rotation started with, some already under the key
    it was rotating to (each individual entry's own rewrite is atomic via
    {!Riptide_storage.File_kv_store.put}'s existing write-temp-then-rename path, but there is no
    transaction spanning the whole rotation; see {!rotate_kek}'s own doc for the precise
    atomicity claim). An operator or caller recovering from exactly that state needs a way to try
    a SPECIFIC candidate key against a specific entry without first needing [t]'s own [kek] field
    to already hold the right one for that entry -- that is exactly what this function is. It has
    no security property of its own beyond {!decrypt}'s: it is exactly as safe, and exactly as
    "None on every failure, never an exception," as {!decrypt}, parameterized over which key gets
    tried. *)

val enumerate_event_ids : t -> string list
(** [enumerate_event_ids t] returns every [event_id] this keystore currently holds a wrapped DEK
    for -- i.e. every [event_id] that has been {!encrypt_for_storage}d and not since {!redact}ed --
    with no external log replay needed (Task 24).

    Before this task, this was not possible from the keystore alone: {!Riptide_storage.File_kv_store}
    hashes every KV key before it ever reaches disk, so nothing about the [event_id]s themselves
    survived on disk in a form anything could enumerate. {!encrypt_for_storage} now embeds
    [event_id] in the clear inside the record's own VALUE for exactly this reason; this function
    folds over the keystore's internal (hashed) identifiers via
    {!Riptide_storage.File_kv_store.fold}, reads each one back via
    {!Riptide_storage.File_kv_store.get_by_hash}, and decodes the embedded [event_id] out.

    No ordering guarantee on the returned list, matching {!Riptide_storage.Kv_store_intf.S.fold}'s
    own "no ordering guarantee whatsoever" -- sort the result if a caller needs a stable order.

    A record that fails to decode in the expected embedded-[event_id] format is skipped rather than
    raising, so one bad or foreign record does not prevent enumerating every other, legitimate one
    -- see this module's own [.ml] ([enumerate_event_ids]'s comment) for why that specific failure
    mode is believed unreachable in practice for a keystore this module fully controls the format
    of, and for the honest disclosure of what silently skipping it actually costs. *)

exception Undecryptable_entry of string
(** Raised by {!rotate_kek} for the [event_id] of an entry whose wrapped DEK authenticates under
    neither the key rotation started with nor the key it is rotating to. See {!rotate_kek}'s own
    doc for why this is a deliberate, loud failure rather than a silent skip -- and, critically,
    for a real precondition on resuming an interrupted rotation whose violation raises this exact
    exception on perfectly intact data, not just on genuine corruption.

    The payload is the bare [event_id] (so a catching caller can act on it programmatically,
    e.g. to list every affected entry across a batch), but this module also registers a
    {!Printexc.register_printer} for it: the human-facing message
    ({!Printexc.to_string}/an uncaught top-level backtrace) additionally explains both possible
    root causes and suggests the wrong-resume-key one first, since misdiagnosing a recoverable
    "wrong key used to resume" state as "my data is corrupted" during an active KEK-compromise
    incident is a real, costly mistake this module can cheaply help an operator avoid -- even
    though it cannot mechanically tell the two apart (see {!rotate_kek}'s doc for why not: {e any}
    key material that could disambiguate them, e.g. a fingerprint of the key actually in the
    stored wrap, is exactly the kind of thing this module's sibling {!Kek} module deliberately
    never exposes). *)

val rotate_kek : t -> new_kek:Kek.t -> unit
(** [rotate_kek t ~new_kek] is the KEK-compromise remediation path: before this function existed,
    the only way to recover from a compromised (or merely due-for-rotation) KEK was to destroy
    every record this keystore protects, since nothing could re-wrap them under a fresh key. This
    re-wraps every DEK the keystore currently holds -- the DEK bytes themselves never change, only
    which key wraps them -- under [new_kek], then switches [t] itself over so every subsequent
    {!encrypt_for_storage}/{!decrypt} call made through this same [t] immediately uses the new key.

    {b Mechanically:} enumerates every live [event_id] via {!enumerate_event_ids} (Task 24 -- no
    separate enumeration mechanism is built here), and for each one, unwraps its current DEK and
    re-wraps the identical bytes under [new_kek] with the same [~aad:event_id] binding
    {!encrypt_for_storage} already uses, writing the new record back via
    {!Riptide_storage.File_kv_store.put} -- the exact same atomic per-key write path
    {!encrypt_for_storage} itself uses (write-temp-then-rename, Tasks 15/16; nothing new is built
    here). Only once every entry has been handled without error does [t]'s own [kek] field
    actually change.

    {b Atomicity, stated precisely: per-entry, never cross-entry.} Each individual entry's
    rewrite is atomic -- a crash mid-write of ONE entry can never leave that one entry readable as
    a torn mix of its old and new wrapped bytes; a subsequent read of it sees either the fully-old
    or the fully-new record, in full. There is, deliberately, no transaction spanning the whole
    rotation: a crash between two entries' writes leaves a real, readable keystore where some
    entries are wrapped under the old key and some under [new_kek], and [t]'s own [kek] field is
    still the OLD key (the final assignment never ran, since it only runs after every entry above
    it succeeds). This is disclosed, expected behavior, not a defect -- see the resumability point
    below for the intended way to recover from exactly this state.

    {b Resumability -- a deliberate design choice, not a default landed on silently.} A second
    call to [rotate_kek] after a first attempt was interrupted partway is fully supported and {b
    is} the intended recovery path, rather than requiring an operator to somehow reconstruct which
    entries already rotated: for each entry, this function first tries to unwrap it under the key
    [t] held when THIS call started (the "old" key for this call) and, only if that fails, tries
    [new_kek] before giving up -- a successful unwrap under [new_kek] is treated as "already
    rotated by an earlier attempt" and the entry is left untouched rather than rewritten a second
    time. This makes a re-run after a partial failure naturally idempotent: already-rotated
    entries are skipped, not-yet-rotated entries are completed, and the final [t.kek <- new_kek]
    assignment runs once every entry -- old, already-new, or newly-rotated in this call -- is
    accounted for. The alternative (raise immediately on any entry not readable under the OLD key,
    forcing an operator to manually track rotation progress across a crash) was considered and
    rejected as strictly worse with no compensating benefit: {!decrypt_with} above already has to
    exist for other reasons (see its own doc), so trying both candidate keys per entry costs one
    extra, cheap {!Kek.unwrap} attempt, and turns "an operator must reconstruct partial progress by
    hand before it's safe to try again" into "just call [rotate_kek] again."

    {b Why trying old-then-new is unambiguous, not merely convenient:} an entry can never
    plausibly authenticate under {e both} candidate keys. {!Kek.unwrap} is AES-256-GCM
    authenticated decryption -- succeeding under the wrong key (or the wrong [~aad], which here is
    always this same [event_id] either way) requires forging a 128-bit GCM tag, at ~2^-128 odds.
    So for any real entry, at most one of the two [unwrap_dek_with] attempts below can ever
    succeed; "tries old, falls back to new" never has to arbitrate a genuine ambiguity between the
    two outcomes, it only ever distinguishes "not yet rotated" from "already rotated" cleanly.

    {b A REAL PRECONDITION this resumability design places on the caller, stated plainly: a
    resumed call MUST pass the exact same [~new_kek] the abandoned attempt used.} The fallback
    above only ever tries two keys -- THIS call's own [old_kek] (whatever [t.kek] is right now)
    and THIS call's own [new_kek] (the argument just passed) -- it has no way to try a THIRD key
    it was never told about. Concretely: [rotate_kek t ~new_kek:kek2] is interrupted after
    rewrapping some entries to [kek2], leaving [t.kek] still [kek1]; if the resuming call is
    instead [rotate_kek t ~new_kek:kek3] (a different replacement key -- plausible if an operator
    regenerates a fresh key on retry rather than reusing the abandoned attempt's), every
    already-[kek2]-wrapped entry now fails to unwrap under BOTH this call's candidates ([kek1] and
    [kek3]) -- it is wrapped under neither. Those entries raise {!Undecryptable_entry} below even
    though they are perfectly intact and trivially recoverable (by retrying with [kek2]). This is
    a real, disclosed false-positive in the corruption diagnosis just below, not a hypothetical
    edge case: {b always resume an interrupted rotation with the identical [~new_kek] the
    abandoned attempt was given.} See {!Undecryptable_entry}'s own doc for how its exception
    message is written to actively steer an operator toward suspecting exactly this, rather than
    assuming genuine corruption, the moment it fires.

    {b Idempotent in final state, not in I/O cost.} A redundant call with the SAME [~new_kek] --
    after a rotation already completed, or racing an equivalent concurrent call -- is harmless and
    converges to the identical end state ([t.kek = new_kek], every entry wrapped under it), but is
    not a cheap no-op: every entry still gets read, its DEK unwrapped, re-wrapped, and rewritten to
    disk, exactly as a real rotation would, because nothing here distinguishes "trivially
    already-correct" from "needs rewriting" any more cheaply than actually trying the unwrap.
    Calling [rotate_kek] with a [~new_kek] equal to [t.kek] already (e.g. immediately after a
    successful rotation) still pays this full pass over every entry for zero effect.

    {b A record that fails to unwrap under EITHER key raises {!Undecryptable_entry}[ event_id],
    immediately, stopping the rotation right there} -- deliberately {b not} the same
    "cannot-distinguish, skip silently" tolerance {!enumerate_event_ids} uses for its own two
    silent-skip cases. Those are read-time ambiguities about records that may never have existed
    coherently to begin with (a concurrent delete racing the fold; a foreign write this module
    never produced). This is a different situation: {!enumerate_event_ids} just found this exact
    [event_id] to be live and readable moments before, in the very same call -- for it to then not
    open under either key this rotation knows about is {e usually} real, otherwise-silent
    corruption on an operation whose entire job is re-keying every entry it can see -- {b but, per
    the precondition above, can also be a perfectly intact entry rotated by an abandoned earlier
    call that used a different [~new_kek]} than this one. Skipping either case silently would
    leave a permanently stuck entry (undecryptable forever once rotation eventually completes and
    [t] drops the old key, with no signal anywhere that this ever happened). Raising instead stops
    the rotation with the offending [event_id] named, leaves that entry and everything
    {!enumerate_event_ids} had not yet reached still under the OLD key (fully recoverable, since
    [t.kek] is untouched by a failed call), and leaves every entry already rotated earlier in this
    same call intact and readable under [new_kek] -- consistent with this codebase's established
    preference for a loud, investigable failure over a quiet, unrecoverable one (e.g. this
    module's own {!redact} durability disclosures, or the project's Task 13 superblock-rebuild and
    Task 21 exception-narrowing work). The two possible root causes are genuinely indistinguishable
    from inside this function (both look identical: "neither key opens it"), which is exactly why
    {!Undecryptable_entry}'s own message names both candidates and suggests the wrong-resume-key
    explanation first, rather than reporting a bare "corrupted" that would send an operator
    straight to assuming data loss.

    {b Concurrency.} [t]'s [kek] field is genuinely mutable as of this task (it was immutable
    before) -- calling [rotate_kek] concurrently with itself, or with a concurrent
    {!encrypt_for_storage}/{!decrypt} through the SAME [t] that expects a single, stable key for
    its whole operation, is not safe: such a caller may observe either key, exactly as any
    unsynchronized mutable-field read/write race would. This is not a new class of unsafety this
    module did not already have -- see this module's own header on concurrency: a [t] was already
    documented as "only as safe to share as the underlying
    {!Riptide_storage.File_kv_store.t}, and no safer," and every individual
    {!Riptide_storage.File_kv_store.get}/[put] call [rotate_kek] performs is exactly as safe (or
    unsafe) under concurrent use as any other caller's own use of that same [kv] would be.

    @raise Undecryptable_entry if some entry's wrapped DEK authenticates under neither the key [t]
    held when this call started nor [new_kek]. *)

val redact : t -> event_id:string -> unit
(** [redact t ~event_id] deletes [event_id]'s wrapped DEK from the keystore. This is the whole of
    redaction: the ciphertext, the envelope, and every content hash in the chain are left
    untouched, and the payload becomes unrecoverable through this module because the only key that
    could ever have opened it is gone. A no-op if [event_id] was never stored or was already
    redacted.

    {b Exactly how strong "unrecoverable" is here, stated honestly rather than absolutely} (review
    finding, 2026-09-23 -- this module previously claimed unqualified durable unrecoverability,
    which overclaimed on two real points):

    - {b Durability of the deletion itself is as strong as
      {!Riptide_storage.File_kv_store.delete}'s, and no stronger.} That backend unlinks the key's
      own file and then fsyncs the containing directory, so the removal survives a crash
      immediately after this function returns. Against a {e different}
      {!Riptide_storage.Kv_store_intf.S} backend, redaction inherits whatever durability that
      backend's own [delete] provides -- an in-memory store's [delete], for instance, survives
      nothing.
    - {b No scrub: the DEK's bytes are not overwritten before the unlink.} Unlinking releases the
      file's blocks without erasing them, so the wrapped DEK may remain forensically recoverable
      from unallocated disk blocks (and from any filesystem journal, snapshot, or backup that
      captured it) until those blocks are reused. Such a recovered blob is still wrapped, so it is
      useless without the KEK -- redaction is therefore robust against an adversary who can read
      raw disk but not against one who holds the KEK {e and} can read raw disk. Destroying the KEK
      (which destroys every record's recoverability at once) or storing the keystore on an
      encrypted volume are the mitigations available today; a real scrub-on-delete is a larger
      change, deliberately out of scope, not something this function quietly does.

    {b The keystore is unreplicated, while the log it protects is replicated.} A [t] holds its
    wrapped DEKs in one ordinary local {!Riptide_storage.File_kv_store.t} directory on one
    machine, whereas the ciphertext those DEKs open is replicated byte-identically to every
    replica by VSR. Losing that single directory therefore makes every record it covers
    unrecoverable cluster-wide -- strictly weaker durability than the log itself has. This cuts
    both ways for redaction: it is what makes a redaction cheap and complete (one deletion, one
    place), and it is also a real single point of failure that an encrypted deployment must
    address out of band, by backing up or replicating the keystore directory with the same care
    the KEK file gets. See {!Riptide_batch_commit.Batch_commit.propose}'s own doc comment for how
    this plays out across a view change. Replicating the keystore -- including what redaction
    would then have to mean -- is out of scope here and tracked as its own future task. *)

val payload_of_ciphertext : string -> Riptide.Value.value
(** [payload_of_ciphertext ct] is the canonical way this codebase carries ciphertext inside a
    {!Riptide.Value.value}: [Value.Scalar (Value.Bytes ct)]. Exposed so callers (and tests) can
    build the exact envelope payload {!encrypt_value} produces without re-deciding the wrapping. *)

val encrypt_value : t -> event_id:string -> Riptide.Value.value -> Riptide.Value.value
(** [encrypt_value t ~event_id v] is {!encrypt_for_storage} with its result wrapped by
    {!payload_of_ciphertext} -- the shape an envelope payload actually needs. This is the function
    a {!Riptide_batch_commit.Batch_commit.encryption_sink} is built from. *)

val decrypt_value : t -> event_id:string -> Riptide.Value.value -> Riptide.Value.value option
(** [decrypt_value t ~event_id payload] is the inverse of {!encrypt_value}, applied to an
    envelope's own [payload] field. [None] for everything {!decrypt} returns [None] for, and also
    if [payload] is not shaped like {!payload_of_ciphertext}'s output at all (e.g. a plaintext
    payload from a write that never opted into encryption). *)
