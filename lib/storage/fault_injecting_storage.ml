(* See fault_injecting_storage.mli for the full design rationale. Summary of the one tricky bit:
   [t] wraps an arbitrary [Storage_intf.S]-conforming module + its own value together, which OCaml
   modules can't express as an ordinary record field (the module's own [t] is a different type per
   instantiation) -- so [t] is a GADT with one constructor that existentially quantifies over that
   type, following the standard OCaml idiom for "a first-class module plus a value of its abstract
   type, packaged so the type variable doesn't leak into this module's own [t]". *)

module Int_set = Set.Make (Int) (* same local convention as lib/vsr/replica.ml's own recv_svc *)

type fault_config = {
  drop_probability : float;
  corrupt_probability : float;
  superblock_loss_probability : float;
}

let default_fault_config =
  { drop_probability = 0.0; corrupt_probability = 0.0; superblock_loss_probability = 0.0 }

type t =
  | T : {
      module_ : (module Storage_intf.S with type t = 'a);
      value : 'a;
      prng : Riptide_sim.Prng.t;
      mutable fault_config : fault_config;
      faults_max : int;
      mutable corrupted_slots : Int_set.t;
          (* op_numbers this module has itself corrupted and that haven't since been truncated
             away -- see the .mli's [create] doc comment for why this is a conservative, not
             exact, count once the wrapped backend's own eviction (e.g. ring wraparound) is in
             play. *)
      mutable dropped_slots : Int_set.t;
          (* op_numbers this module has itself dropped and that haven't since been truncated away
             -- see the .mli's [drop_probability] doc comment. Same masking technique as
             [corrupted_slots], same restart-persistence limitation, deliberately *not* subject to
             [faults_max] (see that doc comment for why). *)
      mutable superblock_lost : bool;
          (* Set when a [superblock_write] is torn by [superblock_loss_probability] (or by
             [for_test_lose_superblock]); cleared by the next superblock write that is NOT torn.
             Masks [superblock_read] to [None] here, the same technique [corrupted_slots] uses for
             the WAL -- see the .mli's own [superblock_loss_probability] doc comment for what is
             also done to the WRAPPED backend's copy, and why both halves are needed. *)
    }
      -> t

let create (type a) ~prng ?(fault_config = default_fault_config) ~replication_quorum
    ~underlying:(module U : Storage_intf.S with type t = a) (value : a) =
  T
    { module_ = (module U : Storage_intf.S with type t = a);
      value;
      prng;
      fault_config;
      faults_max = replication_quorum - 1;
      corrupted_slots = Int_set.empty;
      dropped_slots = Int_set.empty;
      superblock_lost = false
    }

let set_fault_config (T r) fault_config = r.fault_config <- fault_config

(* XOR-flips one deterministically-chosen byte of [data], content-seeded via
   [Prng.int prng (String.length data)] -- so which byte gets flipped depends on both [prng]'s
   current draw and [data]'s own length, and (since this is only ever called once, at write time,
   never re-invoked against the same entry on a later read) the corruption is permanent: nothing
   about a later [wal_read] retries this decision or could possibly find the entry "healed".
   A no-op for an empty string -- there is no byte to flip. *)
let flip_one_byte prng data =
  let len = String.length data in
  if len = 0 then data
  else begin
    let pos = Riptide_sim.Prng.int prng len in
    let bytes = Bytes.of_string data in
    Bytes.set bytes pos (Char.chr (Char.code (Bytes.get bytes pos) lxor 0xFF));
    Bytes.unsafe_to_string bytes
  end

let wal_append (T r) ~op_number data =
  let module U = (val r.module_) in
  (* Fault decisions are always drawn in the same order regardless of which branch is taken, so
     the sequence of draws from [r.prng] depends only on the sequence of [wal_append] calls, not
     on which faults happened to fire along the way -- matching [Network.schedule]'s own
     discipline of drawing every fault decision unconditionally at the point of the call. *)
  let dropped = Riptide_sim.Prng.bool r.prng r.fault_config.drop_probability in
  let corrupt = Riptide_sim.Prng.bool r.prng r.fault_config.corrupt_probability in
  if dropped then begin
    (* Still delegated -- with empty content standing in for "nothing useful was actually
       retained" -- so the wrapped backend's own [wal_highest_op_number] advances exactly as a
       well-behaved caller expects (and so does this module's own, a direct passthrough below),
       which is what keeps the caller's very next legitimate sequential [wal_append] from hitting
       the wrapped backend's out-of-order guard. [wal_read] below unconditionally masks this
       op_number to [None] regardless of what the wrapped backend reports -- see the .mli's
       [drop_probability] doc comment for the full reasoning, including why an earlier version of
       this module that skipped delegation outright was a real bug, not just an omission. *)
    U.wal_append r.value ~op_number "";
    r.dropped_slots <- Int_set.add op_number r.dropped_slots
  end
  else if corrupt && String.length data > 0 then begin
    if Int_set.cardinal r.corrupted_slots >= r.faults_max then
      invalid_arg "faults_max exceeded"
    else begin
      U.wal_append r.value ~op_number (flip_one_byte r.prng data);
      r.corrupted_slots <- Int_set.add op_number r.corrupted_slots
    end
  end
  else U.wal_append r.value ~op_number data

(* A corrupted slot always reads as [None] from *this* [t], regardless of what the wrapped
   backend's own checksum machinery thinks -- and deliberately does not rely on that machinery to
   agree. [flip_one_byte]'s output is still fully self-consistent by the time it reaches [U]:
   [U.wal_append] computes its own checksum from exactly the (already-flipped) bytes it receives,
   so a real [Storage_intf.S] implementation like [File_storage] (which has no way to know the
   bytes it was handed differ from what the caller "really" meant) durably stores a checksum that
   matches the corrupted data and would happily hand it back as [Some corrupted_data] on its own.
   [corrupted_slots] is what actually makes the corruption externally observable as [None] here --
   the byte flip itself only matters for what ends up durably on disk (relevant to a later reader
   that bypasses this wrapper entirely, e.g. a differently-implemented recovery path), not for
   this wrapper's own [wal_read]. *)
let wal_read (T r) ~op_number =
  if Int_set.mem op_number r.corrupted_slots || Int_set.mem op_number r.dropped_slots then None
  else
    let module U = (val r.module_) in
    U.wal_read r.value ~op_number

let wal_truncate_after (T r) ~op_number =
  let module U = (val r.module_) in
  U.wal_truncate_after r.value ~op_number;
  r.corrupted_slots <- Int_set.filter (fun n -> n <= op_number) r.corrupted_slots;
  r.dropped_slots <- Int_set.filter (fun n -> n <= op_number) r.dropped_slots

(* A direct passthrough is correct (not desynced from what a caller expects) precisely because
   [wal_append] above always delegates now, dropped or not -- the wrapped backend's own
   [wal_highest_op_number] advances on every call this module accepts, so there is no separate
   "wrapper's own view" to maintain independently. This was the actual bug the drop-then-crash
   regression traced to: an earlier version that skipped delegation on a drop left this passthrough
   silently behind the wrapper's own bookkeeping instead of in sync with it. *)
let wal_highest_op_number (T r) =
  let module U = (val r.module_) in
  U.wal_highest_op_number r.value

(* The DETERMINISTIC counterpart of the [corrupt_probability] path above -- see the .mli for the
   full rationale. Two implementation points worth stating next to the code:

   1. WHY TRUNCATE-AND-REWRITE RATHER THAN AN IN-PLACE PATCH. [Storage_intf.S] has no
      random-access write at all: [wal_append] extends by exactly one op_number and rejects
      anything else. So the only way to reach an ALREADY-WRITTEN slot through the wrapped
      backend's own machinery -- which is the point, the bytes must really change on the real
      backend, not merely be masked here -- is to truncate back to just below it, rewrite it
      flipped, and re-append whatever was above it. [replica.ml]'s own [adopt_durable_log] repairs
      a corrupt slot by exactly the same three moves, for exactly the same reason.
   2. WHY [U.*] DIRECTLY RATHER THAN THIS MODULE'S OWN [wal_truncate_after]/[wal_append]. Going
      through this module's own operations would (a) run the truncate's [corrupted_slots]/
      [dropped_slots] filter, wiping the bookkeeping for every slot above the victim even though
      those slots are about to be restored verbatim, and (b) subject the restoring appends to the
      probabilistic fault path, so restoring the suffix could itself inject unrelated faults. The
      wrapped backend's own operations are the right level here; this function maintains the
      wrapper's bookkeeping itself, in the one place it actually changes. *)
let for_test_corrupt_entry (T r) ~op_number =
  let module U = (val r.module_) in
  let highest = U.wal_highest_op_number r.value in
  (* Readability is judged by THIS module's own [wal_read] semantics, not the wrapped backend's:
     a slot already corrupted by this wrapper still reads back as [Some] from [U] (the flipped
     bytes are self-consistent down there -- see [wal_read]'s own comment), so consulting [U]
     alone would let an already-faulted slot be "corrupted" a second time. It has no intact entry
     left to destroy, which is exactly the shape of a test that has lost track of which faults it
     already injected, so it takes the same [Invalid_argument] as an out-of-range op_number. *)
  let original =
    if op_number < 1 || op_number > highest then None
    else if Int_set.mem op_number r.corrupted_slots || Int_set.mem op_number r.dropped_slots then None
    else U.wal_read r.value ~op_number
  in
  match original with
  | None -> invalid_arg "for_test_corrupt_entry: no readable durable entry at that op_number"
  | Some original ->
    (* The same Decision 7 cap the probabilistic path enforces, for the same reason -- an explicit
       test-only entry point is not a licence to exceed what the replication protocol can
       tolerate. Note this counts slots ALREADY corrupted, so re-corrupting a slot that is already
       in [corrupted_slots] is unreachable here: it has no readable entry, so it failed above. *)
    if Int_set.cardinal r.corrupted_slots >= r.faults_max then invalid_arg "faults_max exceeded";
    (* Everything strictly above the victim, as the wrapped backend itself sees it, so it can be
       restored byte-for-byte. A slot the WRAPPED backend cannot read (already corrupt beneath
       this wrapper) has no bytes to restore; it is rewritten as an empty entry, which is still
       not a decodable value to any reader -- so it stays "holds something unreadable" (VSR.tla's
       "corrupt"), never "provably never written" ("absent"), which is the distinction the whole
       nack-soundness argument rests on. This wrapper's own [corrupted_slots]/[dropped_slots]
       bookkeeping for those slots is deliberately left in place, so they also keep reading back
       as [None] from here. *)
    let suffix =
      List.init (highest - op_number) (fun i ->
          let o = op_number + 1 + i in
          (o, U.wal_read r.value ~op_number:o))
    in
    U.wal_truncate_after r.value ~op_number:(op_number - 1);
    U.wal_append r.value ~op_number (flip_one_byte r.prng original);
    List.iter (fun (o, bytes) -> U.wal_append r.value ~op_number:o (Option.value bytes ~default:"")) suffix;
    r.corrupted_slots <- Int_set.add op_number r.corrupted_slots

(* The durable artifact a torn superblock write leaves behind on the WRAPPED backend. Deliberately
   a FIXED, self-describing string rather than a byte-flip of the real record: flipping a byte of a
   canonically-encoded superblock can perfectly well yield a record that still DECODES, just with
   different field values -- a plausible-looking wrong superblock, which is a different and nastier
   fault than the one being modelled ("this replica's superblock is gone") and would make a seeded
   run's outcome depend on which byte the flip happened to land in. This string cannot decode as
   the 4-integer record [Riptide_vsr.Replica]'s own [superblock_decode] requires, so every reader
   of the wrapped backend -- including one that bypasses this wrapper entirely, e.g. a fresh
   process reopening a real [File_storage] -- gets "unusable", never "usable but wrong". *)
let torn_superblock_marker = "riptide: fault-injected torn superblock write"

(* THE SUPERBLOCK FAULT (final-review finding I1). Modelled at WRITE time, like [wal_append]'s own
   drop/corrupt faults and for the same reason: the real-world event is a CRASH partway through
   [File_storage.superblock_write]'s 3 sequential, non-atomic copy writes (each itself a header
   write then a data write). A copy whose header landed but whose data did not fails its own
   checksum, so it does not verify at all -- and 1 new + 1 torn + 1 old leaves no 2 copies
   agreeing, which is exactly when [superblock_read] honestly returns [None].

   BOTH halves are performed, matching what [for_test_corrupt_entry] already does for the WAL:
   this wrapper masks its own [superblock_read] to [None] (so the fault is observable through the
   [t] the harness is holding), AND the wrapped backend's own copy is durably replaced with an
   unusable record (so the fault is real down there too, not merely bookkeeping up here). Without
   the first half a caller holding this [t] would see nothing; without the second, re-wrapping the
   same backend -- exactly what a real process restart does -- would silently "heal" it.

   The draw is unconditional, before the branch, keeping this module's own documented discipline:
   the sequence of draws from [r.prng] depends only on the sequence of calls, never on which faults
   fired.

   DELIBERATELY NOT SUBJECT TO [faults_max], and this is a judgment call worth stating. That cap
   exists because more than [replication_quorum - 1] corrupted copies of the SAME WAL SLOT makes
   that slot unrecoverable by any quorum read -- a safety property. A lost superblock is not that:
   it is local to one replica, and (since finding C1's fix) its consequence is that the replica
   REFUSES TO RESTART, i.e. it is down. Losing it on every replica at once therefore costs
   liveness, not safety, and liveness loss is exactly what the sweep's own non-vacuity assertions
   already detect. Capping it would also make the fault undeliverable in the regime that matters
   most -- a cluster where several replicas crash with torn superblocks is the interesting one. *)
let superblock_write (T r) data =
  let module U = (val r.module_) in
  let torn = Riptide_sim.Prng.bool r.prng r.fault_config.superblock_loss_probability in
  if torn then begin
    U.superblock_write r.value torn_superblock_marker;
    r.superblock_lost <- true
  end
  else begin
    U.superblock_write r.value data;
    (* A superblock write that COMPLETES repairs a previously torn one -- which is a real
       property, not a convenience: a replica that comes back up and writes a fresh superblock has
       a usable one again. *)
    r.superblock_lost <- false
  end

let superblock_read (T r) =
  if r.superblock_lost then None
  else
    let module U = (val r.module_) in
    U.superblock_read r.value

(* The DETERMINISTIC counterpart of [superblock_loss_probability], exactly as
   [for_test_corrupt_entry] is the deterministic counterpart of [corrupt_probability], and for the
   same reason: the probabilistic path only ever fires at write time, so a test that has already
   settled a cluster into a known-good state has no write left to attach the fault to. Same two
   halves, same durable marker. *)
let for_test_lose_superblock (T r) =
  let module U = (val r.module_) in
  U.superblock_write r.value torn_superblock_marker;
  r.superblock_lost <- true
