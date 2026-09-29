type hash = string

type scalar =
  | Bool of bool
  | Int of int64
  | Float of float
  | String of string
  | Bytes of string

type value =
  | Scalar of scalar
  | Record of (string * value) list
  | Sum of string * value
  | Sequence of value list
  | Map of (value * value) list

(* Every variable-length piece (strings, bytes, list lengths) is prefixed
   with its length as a fixed 8-byte big-endian integer before its
   content, so concatenating the encodings of two different values can
   never be mistaken for the encoding of a third. Every constructor also
   gets a distinct 1-byte tag so different shapes never collide either. *)

let tag_scalar_bool = '\x00'
let tag_scalar_int = '\x01'
let tag_scalar_float = '\x02'
let tag_scalar_string = '\x03'
let tag_scalar_bytes = '\x04'
let tag_record = '\x05'
let tag_sum = '\x06'
let tag_sequence = '\x07'
let tag_map = '\x08'

(* A minimal growable byte buffer, like [Buffer.t], but additionally
   supporting in-place patching of already-written bytes at a fixed offset
   ([reserve]/[patch_u64_be] below). [Buffer.t] itself has no supported way
   to mutate bytes once added (its own [blit] only copies *out* of a
   buffer, never into one), which is exactly the capability [encode_into]'s
   [Map] single-entry case (see there) needs to write a key's 8-byte length
   prefix *before* the key's own bytes without first measuring those bytes
   in a separate buffer.

   History: the first version of this fix (see git history) instead
   precomputed a full parallel [sized_value] tree ([size] on every node,
   mirroring [value]'s own shape) in one eager pass ahead of encoding, so
   [encode_into] could read a subtree's size as a plain field instead of
   measuring it. That worked - it made a single-entry Map-key chain's
   length prefixes O(1) each instead of re-measuring per level - but it
   held an entire second copy of the value's shape (one [sized_value]
   record + one [sized_shape] block per input node) live in memory
   *simultaneously* with both the input [value] and the output buffer, for
   every value encoded, not just ones with deep Map-key chains. Measured on
   the original reviewer's own reproduction input (a 2-million-element
   [Sequence] of [Bool] with distinct blocks, no [Map] anywhere in it):
   peak heap during [canonical_encode] with this [sized_value] shadow tree
   reached 241.2 MiB - a regression on the exact memory axis this task
   exists to improve, paid by every caller, unconditionally (audit finding
   I1). [Wbuf] below removes the shadow tree and brings that same
   reproduction's peak down to 152.8 MiB (a ~37% reduction). These are the
   reconciled, authoritative figures - see task-5-report.md's Finding I1
   section for the full reproduction; two earlier, differently-scoped
   measurements (taken with different repro inputs and never reconciled
   against each other) previously disagreed with these and with each
   other, and are superseded by these numbers.

   [Wbuf] removes the shadow tree entirely: [encode_into] walks the real
   [value] tree once, writing directly into the growable output buffer,
   and gets a length it needs *before* the corresponding bytes exist yet
   (the single-entry Map-key case) by reserving 8 zero bytes at the
   current write position, encoding the key directly after that
   reservation, then patching the reserved bytes with the actual length
   once it's known (the buffer's own tracked length minus the position
   right after the reservation). This costs O(1) extra bookkeeping per
   reservation (an int offset, implicitly held on the OCaml call stack via
   [encode_into]'s own recursion) instead of O(total nodes) of persistent
   shadow-tree memory. *)
module Wbuf = struct
  type t = { mutable bytes : Bytes.t; mutable len : int }

  let create n = { bytes = Bytes.create (max n 16); len = 0 }

  let ensure t extra =
    let needed = t.len + extra in
    if needed > Bytes.length t.bytes then begin
      let new_cap = ref (max 16 (Bytes.length t.bytes)) in
      while !new_cap < needed do
        new_cap := !new_cap * 2
      done;
      let new_bytes = Bytes.create !new_cap in
      Bytes.blit t.bytes 0 new_bytes 0 t.len;
      t.bytes <- new_bytes
    end

  let add_char t c =
    ensure t 1;
    Bytes.set t.bytes t.len c;
    t.len <- t.len + 1

  let add_string t s =
    let n = String.length s in
    ensure t n;
    Bytes.blit_string s 0 t.bytes t.len n;
    t.len <- t.len + n

  let length t = t.len

  (* Writes [n] zero bytes at the current position and returns the offset
     they start at, so a caller can go back and fill them in later via
     [patch_u64_be] once it knows what belongs there. *)
  let reserve t n =
    let off = t.len in
    ensure t n;
    Bytes.fill t.bytes off n '\x00';
    t.len <- t.len + n;
    off

  (* Overwrites the 8 bytes at [off] (which must already have been written,
     typically via [reserve]) with [n] as a big-endian u64. Safe to call
     after further bytes have been appended past [off] - and, crucially,
     after the underlying [bytes] array has been reallocated by [ensure]
     one or more times in between, since this always writes through the
     buffer's *current* [t.bytes], not a reference captured at reserve
     time. *)
  let patch_u64_be t off (n : int) =
    for i = 0 to 7 do
      Bytes.set t.bytes (off + i) (Char.chr ((n lsr (8 * (7 - i))) land 0xff))
    done

  let contents t = Bytes.sub_string t.bytes 0 t.len
end

let write_u64_be buf (n : int) =
  for i = 7 downto 0 do
    Wbuf.add_char buf (Char.chr ((n lsr (8 * i)) land 0xff))
  done

let buf_add_len_prefixed buf s =
  write_u64_be buf (String.length s);
  Wbuf.add_string buf s

(* Walks a list already sorted by [compare_key] and raises [Invalid_argument]
   on the first pair of adjacent entries whose keys compare equal — i.e. a
   duplicate key. Used by [encode_into]'s [Record]/[Map] cases so that a
   duplicate key is rejected even when the [value] was built directly in
   memory (never round-tripped through [canonical_decode], which enforces
   the same rule from the wire-bytes side — see [decode_value] below). A
   sorted list only ever needs an adjacent check: [List.stable_sort] groups
   equal keys next to each other regardless of their original position. *)
let reject_duplicate_keys ~what compare_key sorted =
  let rec loop = function
    | [] | [ _ ] -> ()
    | a :: (b :: _ as rest) ->
      if compare_key a b = 0 then invalid_arg (Printf.sprintf "canonical_encode: duplicate %s key" what);
      loop rest
  in
  loop sorted

(* Sorts [entries] by [compare_key] (stable, matching [encode_into]'s own historical
   sort behavior) and then rejects a duplicate key against that exact same comparator.
   Defined once and shared by both the [Record] and [Map] encode arms below so the
   comparator governing canonical order and the comparator governing "is this a
   duplicate" can never independently drift apart - each call site passes one
   [compare_key] value that does both jobs, instead of writing out the same
   comparator lambda twice per site and relying on the two copies staying in sync by
   hand (finding 2, task-6 review). *)
let sort_and_reject_duplicate_keys ~what compare_key entries =
  let sorted = List.stable_sort compare_key entries in
  reject_duplicate_keys ~what compare_key sorted;
  sorted

(* Task 8 (docs/superpowers/plans/2026-09-29-audit-remediation.md): a hard cap on nesting
   depth, enforced identically by [encode_into] and [decode_value] (see each function's own
   ["nesting depth exceeds the limit"] check just inside their entry point) - a [value] tree
   is never more than [max_nesting_depth] [Record]/[Sum]/[Sequence]/[Map] levels deep,
   regardless of whether it arrived via [canonical_decode] from untrusted wire bytes or was
   built directly in memory by this process's own code.

   Two independent reasons this needs to be on BOTH sides, not just decode:

   1. [decode_value] itself: an unbounded-depth input lets an attacker drive OCaml's own
      call stack arbitrarily deep for a wire payload that grows only linearly - not
      exponentially - with depth: as little as ~9 bytes per extra level of nesting via the
      cheapest shape (a single-element [Sequence]: 1 tag byte + an 8-byte count), or ~19
      bytes/level for the single-entry-Map-key-chain shape
      [build_nested_map_key_wire_bytes] in test_value.ml builds - so a chain deep enough to
      exhaust a real stack (order 10^5-10^6 native frames, depending on stack size and this
      function's own frame size) costs an attacker on the order of single-digit MB of wire
      bytes, not gigabytes - a cheap-to-construct stack-exhaustion DoS with no ceiling at
      all before this cap existed.

   2. [encode_into]'s [Map] case, for a [value] with 2+ Map entries at every nesting level:
      per that case's own doc comment above (the "Two or more entries..." branch), this
      remains algorithmically quadratic in depth (Θ(depth × size)) because closing it
      properly needs a byte-lexicographic structural comparator across all 5 constructors -
      judged too risky to build here given how consensus-safety-critical getting canonical
      ordering right is (see this task's own report for the full controller ruling). Capping
      nesting depth at 1000 is the accepted mitigation for that residual: measured directly
      (test_value.ml's [test_two_entries_per_level_deep_map_encode_hash_residual_bounded]),
      a 2-entries-per-level chain at depth 1000 costs ~19ms/~37MB, vs. the same shape at
      depth 20,000 costing ~7s/~14.5GB - the quadratic blowup is still there in the abstract,
      but a depth-1000 ceiling keeps its concrete cost negligible. A [value] built directly in
      memory (never round-tripped through [canonical_decode]) can trigger this exact shape
      just as easily as a decoded one, which is why [encode_into] enforces the same cap
      independently rather than relying on every producer of a deep [value] to have gone
      through [decode_value]'s check first. *)
let max_nesting_depth = 1000

let depth_exceeded_error ~what =
  invalid_arg (Printf.sprintf "%s: nesting depth exceeds the limit of %d levels" what max_nesting_depth)

(* Task 8, Finding 1 (audit-remediation review fix round): a hard budget on the *total number
   of nodes* processed by [encode_into]/[decode_value] (every call - Scalar leaf or
   Record/Sum/Sequence/Map container alike - counts as exactly one), enforced independently of
   [max_nesting_depth] above (that cap bounds recursion/stack depth; this one bounds total heap
   allocation - a wide, shallow tree with millions of siblings costs nothing against the depth
   cap but everything against this one, and vice versa for a deep, narrow chain).

   This is a FIXED ABSOLUTE ceiling, not one scaled to each input's own declared byte length.
   The original Task 8 landing used [max min_decoded_nodes_floor (input_len /
   bytes_per_node_budget)] (10,000-node floor, scaled by 1 node per 64 input bytes past that) -
   see git history. That per-input scaling was itself a real bug: every non-blob [value] shape
   this codebase actually produces (VSR messages, batch_commit records, ...) encodes at roughly
   2-30 wire bytes per node, all well under the 64-bytes/node threshold at which the scaled term
   would ever exceed the 10,000-node floor - so in practice that formula collapsed to a flat
   10,000-node ceiling on every frame, regardless of the frame's actual declared size.
   Concretely, that flat ceiling made this codebase reject its own legitimate traffic:
   [Start_view] carries the entire replicated log as a [Value.Sequence] (lib/vsr/message.ml,
   built at lib/vsr/replica.ml), and [Do_view_change] carries all readable entries similarly -
   and this codebase has no log compaction/snapshotting anywhere (lib/vsr/replica_log.mli), so
   log length only grows. An ordinary long-running cluster's log crosses 10,000 nodes at only
   ~1,000 committed entries (~293 KB - comfortably inside the 64 MiB transport limit), so once a
   cluster's log grew past roughly 1,000 entries, view changes could never complete again - a
   genuine, self-inflicted permanent-liveness-loss bug. Separately, an honest batch of ~2,000
   writes (also well within the 64 MiB transport limit), written durably, would read back as
   permanently [Corrupt] (see [slot_state] in lib/vsr/replica.ml).

   The fix (per this task's own governing spec,
   docs/superpowers/specs/2026-09-29-audit-remediation-design.md, Decision 2.3): derive the
   budget from [lib/transport/tcp.ml]'s [max_message_size] (currently 64 MiB) as an ABSOLUTE
   ceiling, applied regardless of any particular input's own declared length - not a
   per-input-scaled one. [lib/value.ml] (the [riptide] library) cannot depend on
   [lib/transport] ([riptide_transport] depends on [riptide], not the other way around - see
   the dune files), so the constant is mirrored here, with this comment as the mechanism that
   keeps it in sync - the same way test/test_value.ml already mirrors this module's own
   internal constants for its budget-boundary test. If [Tcp.max_message_size] ever changes,
   update [mirrored_transport_max_message_size] below to match in the same change.

   Why a budget at all, given [read_len_prefix]'s existing "claimed count can't exceed
   remaining bytes" check already makes it impossible to claim more nodes than the input could
   physically contain (no compression/back-references in this wire format, so worst-case node
   count is already bounded to roughly (input length / 2) for the cheapest possible node, a
   [Bool] scalar: 1 tag + 1 payload byte): that existing bound is still far too loose, because
   OCaml's own per-node heap overhead turns a compact wire encoding into a much larger live
   in-memory tree. Measured directly (a tight loop allocating [Scalar (Bool b)] cons cells with
   [b] not statically known, so the compiler can't share/constant-fold them - the same shape
   [decode_value]'s own Bool case builds): ~55 bytes of live OCaml heap per node (a 2-word
   [Bool] block + 2-word [Scalar] block + 3-word list cons cell = 7 words = 56 bytes on a
   64-bit runtime), against only 2 bytes of wire encoding - a ~27x amplification even before
   accounting for [decode_value]'s own [List.rev] at the end of each Record/Sequence/Map loop
   transiently doubling that level's own list, or the OCaml major heap's own
   fragmentation/growth-increment overhead on top of raw live-word counts. This matches the
   audit's own reproduction: a worst-case 64 MiB (67,108,864-byte) frame - the size of
   [Tcp.max_message_size], the largest frame this codebase will ever hand to
   [canonical_decode] - packed with cheap [Bool] [Sequence] elements reaches ~9 GB live memory
   with no other protection in place (docs/superpowers/specs/2026-09-29-audit-remediation-design.md,
   Decision 2.3).

   Formula: [max_node_count = mirrored_transport_max_message_size / bytes_per_node_budget], i.e.
   the number of nodes a full 64 MiB frame could contain if every node cost only
   [bytes_per_node_budget] (64) wire bytes - 1,048,576 nodes. Applying this as a FLAT ceiling
   (not scaled down for a smaller input) still gives the identical worst-case memory-safety
   guarantee as before: the cheapest possible attack shape (a flat, all-Bool [Sequence]) still
   hits this ceiling after decoding only ~2 MiB of wire input (at 2 wire-bytes/node), at an
   estimated ~55 MB of live heap (1,048,576 nodes x ~55 bytes/node) - three orders of magnitude
   below the audit's observed ~9 GB - regardless of what byte length the attacker declares for
   the frame. What changes is that a smaller, legitimate, node-DENSE frame (this codebase's
   real payloads run at roughly 2-30 wire bytes/node, not 64) is no longer punished for being
   byte-compact: a 293 KB [Start_view] over 1,000 log entries, or a 2 MiB frame of 2,000
   ordinary batch writes, both stay far under 1,048,576 nodes and decode successfully, exactly
   as they must for the cluster to keep making progress.

   Enforced identically on the encode side (Finding 2, audit-remediation review fix round):
   [encode_into] threads the same node-count budget through its own recursive calls, raising
   past the same [max_node_count] ceiling - matching how [max_nesting_depth] above is already
   symmetric between [encode_into] and [decode_value]. Without this, a [value] built directly
   in memory (never round-tripped through [canonical_decode]) could exceed the budget on
   encode while the equivalent wire bytes would have been rejected on decode - breaking the
   round-trip invariant [value.mli] documents (an honestly-encoded value that
   [canonical_decode] would reject must never be producible by [canonical_encode] in the first
   place) and, concretely, opening a silent data-loss path: [Riptide_crypto.Redaction_store]'s
   decrypt path treats "authenticated under its own DEK but fails to decode" as
   indistinguishable from "never stored" (see its own comment), so an over-budget in-memory
   value that DID successfully encode and get stored durably would read back as [None]
   forever, with no way to tell that apart from an intentionally-redacted value. *)
let mirrored_transport_max_message_size = 64 * 1024 * 1024
let bytes_per_node_budget = 64
let max_node_count = mirrored_transport_max_message_size / bytes_per_node_budget

(* M3 (audit-remediation review fix round): the budget-exceeded error previously reported only
   the budget itself, not the actual observed node count (or, for decode, the input length) -
   since this budget's failure modes elsewhere in the system surface only as generic
   [Malformed_message]/[Corrupt]/[None] (see the doc comment above), an operator debugging one
   of those has no way to tell "genuine attack" from "budget mis-calibrated" without this
   information logged at the point the real decision was made. *)
let node_budget_exceeded_error ~what ~node_count =
  invalid_arg (Printf.sprintf "%s: node count %d exceeds budget of %d nodes" what node_count max_node_count)

let decode_node_budget_exceeded_error ~node_count ~input_len =
  invalid_arg
    (Printf.sprintf "canonical_decode: decoded node count %d exceeds budget of %d nodes for this %d-byte input"
       node_count max_node_count input_len)

let rec encode_into buf ~depth ~node_count (v : value) =
  if depth > max_nesting_depth then depth_exceeded_error ~what:"canonical_encode";
  incr node_count;
  if !node_count > max_node_count then node_budget_exceeded_error ~what:"canonical_encode" ~node_count:!node_count;
  match v with
  | Scalar (Bool b) ->
    Wbuf.add_char buf tag_scalar_bool;
    Wbuf.add_char buf (if b then '\x01' else '\x00')
  | Scalar (Int i) ->
    Wbuf.add_char buf tag_scalar_int;
    for shift = 56 downto 0 do
      if shift mod 8 = 0 then
        Wbuf.add_char buf (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical i shift) 0xffL)))
    done
  | Scalar (Float f) ->
    Wbuf.add_char buf tag_scalar_float;
    let bits = Int64.bits_of_float f in
    for shift = 56 downto 0 do
      if shift mod 8 = 0 then
        Wbuf.add_char buf (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical bits shift) 0xffL)))
    done
  | Scalar (String s) ->
    Wbuf.add_char buf tag_scalar_string;
    buf_add_len_prefixed buf s
  | Scalar (Bytes b) ->
    Wbuf.add_char buf tag_scalar_bytes;
    buf_add_len_prefixed buf b
  | Record fields ->
    Wbuf.add_char buf tag_record;
    let compare_by_key (k1, _) (k2, _) = String.compare k1 k2 in
    let sorted = sort_and_reject_duplicate_keys ~what:"record field" compare_by_key fields in
    write_u64_be buf (List.length sorted);
    List.iter
      (fun (k, v) ->
         buf_add_len_prefixed buf k;
         encode_into buf v ~depth:(depth + 1) ~node_count)
      sorted
  | Sum (tag, v) ->
    Wbuf.add_char buf tag_sum;
    buf_add_len_prefixed buf tag;
    encode_into buf v ~depth:(depth + 1) ~node_count
  | Sequence items ->
    Wbuf.add_char buf tag_sequence;
    write_u64_be buf (List.length items);
    List.iter (fun item -> encode_into buf item ~depth:(depth + 1) ~node_count) items
  | Map entries ->
    Wbuf.add_char buf tag_map;
    write_u64_be buf (List.length entries);
    (match entries with
     | [] -> ()
     | [ (k, v) ] ->
       (* Exactly one entry: there is nothing to sort (a single-element
          order is already "sorted" by definition), so this key can be
          written straight into [buf]: reserve 8 zero bytes for its length
          prefix, encode the key directly after them (writing straight into
          the real output buffer, not a throwaway one), then patch the
          reservation with the number of bytes the key actually took -
          instead of the general multi-entry path below, which must
          materialize full key bytes into a separate buffer to compare
          them. That materialize-then-discard buffer is exactly the shape
          that turned quadratic with nesting depth for a chain of
          single-entry Map keys in the original audited bug (each level's
          *entire* already-built accumulated bytes gets copied out via
          [Buffer.contents] and copied in again via [Buffer.add_string] at
          every level above it - the same doubling that made
          [decode_value]'s old [String.sub]-and-recurse-into-the-copy
          approach quadratic, just on the write side instead of the read
          side). Writing directly here, with the length backfilled after
          the fact, means every byte of a deep single-entry chain is
          written to its final position exactly once, giving O(depth) for
          this shape instead of O(depth^2), with no extra shadow data
          structure needed to know the length up front (see [Wbuf]'s own
          doc comment for why that matters). *)
       let len_off = Wbuf.reserve buf 8 in
       let key_start = Wbuf.length buf in
       encode_into buf k ~depth:(depth + 1) ~node_count;
       Wbuf.patch_u64_be buf len_off (Wbuf.length buf - key_start);
       encode_into buf v ~depth:(depth + 1) ~node_count
     | _ :: _ :: _ ->
       (* Two or more entries genuinely need their full encoded key bytes to
          determine sort order, so this path still materializes each key via
          its own buffer.

          Honest cost of this path, corrected (this comment previously
          claimed the cost here "is bounded by the sibling keys' own sizes
          at this one level, not compounded across nesting depth" - that is
          FALSE and was never actually measured before being written down;
          see the correction and the depth-1000 pinning test below in
          test_value.ml). When every level of a deep chain has 2+ entries
          (not just the outermost), encoding one level materializes its
          child key's full bytes via [Wbuf.contents]-equivalent copy
          (below, [encode_into] into a fresh [kb] then read out via
          [contents]) - and that child key is itself a 2+-entry Map one
          level down, so producing ITS bytes recurses into this same case
          again, one level deeper. The copy-out cost at each of the
          O(depth) levels is proportional to that level's subtree size,
          which is itself O(depth) for a chain - O(depth) levels x O(depth)
          copy each = Θ(depth x size), i.e. still quadratic in depth for
          this 2+-entries-per-level shape. This is the same shape as the
          bug this task exists to fix, just not eliminated by this task's
          in-place rewrite, because that rewrite only made the *single*-key
          fast path above copy-free - it did not (and, per the sorting
          requirement, structurally cannot without a byte-lexicographic
          structural comparator - see the note below) do the same for the
          general multi-key case.

          This remains quadratic in depth for Maps with 2+ entries per
          nesting level - see docs/superpowers/plans/2026-09-29-audit-remediation.md
          Task 8 (landed: [max_nesting_depth]/[depth_exceeded_error] above,
          threaded through BOTH [decode_value] and [encode_into]), which caps
          nesting at 1000 and is the accepted mitigation for this residual -
          not a fix for the underlying Θ(depth x size) algorithm, which is
          still exactly as quadratic as described above, but a ceiling that
          keeps its concrete cost negligible (~19ms/~37MB at depth 1000, per
          test_two_entries_per_level_deep_map_encode_hash_residual_bounded in
          test_value.ml, vs. ~7s/~14.5GB at depth 20,000) rather than
          catastrophic. *)
       let encoded_entries = List.map (fun (k, v) ->
           let kb = Wbuf.create 64 in
           encode_into kb k ~depth:(depth + 1) ~node_count;
           (Wbuf.contents kb, v))
           entries
       in
       let compare_by_key (k1, _) (k2, _) = String.compare k1 k2 in
       let sorted = sort_and_reject_duplicate_keys ~what:"map" compare_by_key encoded_entries in
       List.iter
         (fun (kbytes, v) ->
            buf_add_len_prefixed buf kbytes;
            encode_into buf v ~depth:(depth + 1) ~node_count)
         sorted)

let canonical_encode v =
  let buf = Wbuf.create 256 in
  let node_count = ref 0 in
  encode_into buf v ~depth:0 ~node_count;
  Wbuf.contents buf

(* ---- Decoding ----

   [canonical_decode] is the exact structural inverse of [encode_into]
   above: same tag bytes, same 8-byte big-endian length/count prefixes,
   same field layout per constructor. Every length/count prefix read from
   the input is bounds-checked against what's actually left in the buffer
   BEFORE it is trusted for anything (allocating a list, slicing a
   substring, etc.) — this function will eventually be fed bytes that
   arrived over a network with zero integrity guarantee, so a corrupt or
   adversarial prefix must raise promptly rather than read out of bounds,
   loop "reading" astronomically many entries, or crash with an unhandled
   exception (e.g. an array/string index error). Every raise in this
   section is [Invalid_argument], matching this module's established
   convention (see [hash_to_hex]). *)

(* Every reader below takes an explicit [bound]: the exclusive end offset
   into [s] that the *current* decode is allowed to see, which is [String.length
   s] for a top-level decode but a narrower, key-blob-local end offset while
   decoding a [Map] key in place (see [decode_value]'s [Map] case) — a
   nested decode must never be able to read past its own bound and "borrow"
   bytes that actually belong to the outer stream, even though those bytes
   are still physically present (and in-bounds for [s] itself) beyond it. *)

(* Reads an 8-byte big-endian length/count prefix at [pos] and validates it
   against the bytes actually remaining before [bound] after the prefix
   itself — this one check covers both "truncated prefix" (fewer than 8
   bytes left before [bound] to read the prefix from) and "claimed
   length/count exceeds remaining input" (the prefix decodes fine but names
   more bytes/entries than are available before [bound]). [what] is used
   only to make the raised message descriptive (e.g. "string length",
   "record field count").
   The intermediate accumulation is done in [Int64] specifically so a
   maliciously large 8-byte prefix (top bit set, or otherwise unrepresentable
   as a native non-negative [int]) is rejected by the [v64 < 0L] / [v64 >
   Int64.of_int remaining] comparisons themselves, rather than silently
   wrapping into some smaller (and wrong) native [int] first. *)
let read_len_prefix s pos ~bound ~what =
  if pos + 8 > bound then invalid_arg (Printf.sprintf "canonical_decode: truncated %s length prefix" what);
  let v64 = ref 0L in
  for i = 0 to 7 do
    v64 := Int64.logor (Int64.shift_left !v64 8) (Int64.of_int (Char.code s.[pos + i]))
  done;
  let pos = pos + 8 in
  let remaining = bound - pos in
  if !v64 < 0L || !v64 > Int64.of_int remaining then
    invalid_arg (Printf.sprintf "canonical_decode: %s length %Ld exceeds remaining input (%d bytes)" what !v64 remaining);
  (Int64.to_int !v64, pos)

(* Reads a raw 8-byte big-endian [int64] payload (used for [Int] and
   [Float], whose bit pattern is stored verbatim per [encode_into]). *)
let read_i64_payload s pos ~bound ~what =
  if pos + 8 > bound then invalid_arg (Printf.sprintf "canonical_decode: truncated %s" what);
  let v = ref 0L in
  for i = 0 to 7 do
    v := Int64.logor (Int64.shift_left !v 8) (Int64.of_int (Char.code s.[pos + i]))
  done;
  (!v, pos + 8)

(* Slices out exactly [len] bytes at [pos]. Callers only ever pass a [len]
   already validated by [read_len_prefix] against [bound] — not directly
   against [String.length s] — but [bound] is always [<= String.length s]
   (every caller derives it either from [String.length s] itself, at the
   top level, or from a narrower, already-in-bounds key-blob end offset;
   see the [bound] doc comment above), so [pos + len <= bound <=
   String.length s] holds transitively, and no separate check is needed
   here to stay in bounds. *)
let read_bytes_exact s pos len =
  (String.sub s pos len, pos + len)

(* Lexicographically compares the byte range [s.[a_pos], s.[a_pos+a_len))
   against [s.[b_pos], s.[b_pos+b_len)) directly against the shared buffer
   [s] — same semantics as [String.compare] on the two equivalent
   substrings (shared-prefix bytes decide it; if one range is a strict
   prefix of the other, the shorter one compares smaller), but without
   allocating either substring. This matters specifically for [Map] key
   blobs: they can themselves be arbitrarily large nested encodings (see
   [decode_value]'s [Map] case and Task 5's in-place-decode fix above), so
   comparing two of them via [String.sub]-then-[String.compare] would
   reintroduce exactly the kind of copy this module's decode path was just
   fixed to avoid. Used to check canonical (strictly increasing, duplicate-
   free) key order on decode — see [decode_value]'s [Record]/[Map] cases —
   mirroring the same [String.compare] ordering [encode_into] already
   sorts by, so a canonically-encoded value can never fail its own
   decode-order check. *)
let compare_byte_range s ~a_pos ~a_len ~b_pos ~b_len =
  let min_len = if a_len < b_len then a_len else b_len in
  let rec loop i =
    if i >= min_len then Int.compare a_len b_len
    else
      let c = Char.compare s.[a_pos + i] s.[b_pos + i] in
      if c <> 0 then c else loop (i + 1)
  in
  loop 0

let rec decode_value s pos ~bound ~depth ~input_len ~node_count =
  if depth > max_nesting_depth then depth_exceeded_error ~what:"canonical_decode";
  incr node_count;
  if !node_count > max_node_count then decode_node_budget_exceeded_error ~node_count:!node_count ~input_len;
  if pos >= bound then invalid_arg "canonical_decode: unexpected end of input (expected a value tag byte)";
  let tag = s.[pos] in
  let pos = pos + 1 in
  if tag = tag_scalar_bool then begin
    if pos >= bound then invalid_arg "canonical_decode: truncated bool payload";
    let v =
      match s.[pos] with
      | '\x00' -> false
      | '\x01' -> true
      | c -> invalid_arg (Printf.sprintf "canonical_decode: invalid bool byte 0x%02x" (Char.code c))
    in
    (Scalar (Bool v), pos + 1)
  end
  else if tag = tag_scalar_int then
    let i, pos = read_i64_payload s pos ~bound ~what:"int payload" in
    (Scalar (Int i), pos)
  else if tag = tag_scalar_float then
    let bits, pos = read_i64_payload s pos ~bound ~what:"float payload" in
    (Scalar (Float (Int64.float_of_bits bits)), pos)
  else if tag = tag_scalar_string then
    let len, pos = read_len_prefix s pos ~bound ~what:"string" in
    let str, pos = read_bytes_exact s pos len in
    (Scalar (String str), pos)
  else if tag = tag_scalar_bytes then
    let len, pos = read_len_prefix s pos ~bound ~what:"bytes" in
    let b, pos = read_bytes_exact s pos len in
    (Scalar (Bytes b), pos)
  else if tag = tag_record then
    let count, pos = read_len_prefix s pos ~bound ~what:"record field count" in
    (* [prev_key] is the previously-decoded field name, if any: each new key
       must compare strictly greater than it (per [String.compare], the same
       comparator [encode_into] sorts fields by) or the wire bytes are not a
       valid canonical encoding — either genuinely out of order, or an exact
       duplicate (compares equal). Rejecting both here is what makes
       [canonical_decode] a true inverse of [canonical_encode]: two
       byte-different wire encodings must never decode to values that could
       have distinct [content_hash]es despite representing "the same" record. *)
    let rec loop i pos acc ~prev_key =
      if i = 0 then (List.rev acc, pos)
      else
        let klen, pos = read_len_prefix s pos ~bound ~what:"record field key" in
        let k, pos = read_bytes_exact s pos klen in
        (match prev_key with
         | Some pk ->
           let c = String.compare pk k in
           if c = 0 then invalid_arg (Printf.sprintf "canonical_decode: duplicate record field key %S" k)
           else if c > 0 then
             invalid_arg
               (Printf.sprintf "canonical_decode: record fields are not in canonical order (%S after %S)" k pk)
         | None -> ());
        let v, pos = decode_value s pos ~bound ~depth:(depth + 1) ~input_len ~node_count in
        loop (i - 1) pos ((k, v) :: acc) ~prev_key:(Some k)
    in
    let fields, pos = loop count pos [] ~prev_key:None in
    (Record fields, pos)
  else if tag = tag_sum then
    let tlen, pos = read_len_prefix s pos ~bound ~what:"sum tag" in
    let t, pos = read_bytes_exact s pos tlen in
    let v, pos = decode_value s pos ~bound ~depth:(depth + 1) ~input_len ~node_count in
    (Sum (t, v), pos)
  else if tag = tag_sequence then
    let count, pos = read_len_prefix s pos ~bound ~what:"sequence element count" in
    let rec loop i pos acc =
      if i = 0 then (List.rev acc, pos)
      else
        let v, pos = decode_value s pos ~bound ~depth:(depth + 1) ~input_len ~node_count in
        loop (i - 1) pos (v :: acc)
    in
    let items, pos = loop count pos [] in
    (Sequence items, pos)
  else if tag = tag_map then
    let count, pos = read_len_prefix s pos ~bound ~what:"map entry count" in
    (* [prev_kblob] tracks the previous entry's key blob as (start, len) into
       [s] — not a copied string, see [compare_byte_range] above for why a
       copy here would reintroduce the exact quadratic-in-depth cost Task 5
       just removed. Each new key blob must compare strictly greater than
       the previous one (byte-lexicographically, the same comparator
       [encode_into]'s multi-entry Map path sorts encoded key bytes by) or
       the wire bytes are rejected as either out of canonical order or an
       exact duplicate key. *)
    let rec loop i pos acc ~prev_kblob =
      if i = 0 then (List.rev acc, pos)
      else
        (* The asymmetry vs. Record: a Map entry's key is stored as a
           length-prefixed blob containing the key's OWN recursively
           encoded bytes (see [encode_into]'s [Map] case), not encoded
           inline the way a Record field name is. Previously this blob was
           [String.sub]-copied out of [s] and then recursively decoded from
           position 0 of the copy — at nesting depth N that copies the
           (already-copied) inner N-1 levels again at every level, making
           both time and simultaneously-live memory O(N^2) in the nesting
           depth. Instead: read only the blob's length, decode the key
           directly against the OUTER buffer [s] starting at the current
           position, bounding that nested decode to end exactly at
           [kblob_end] — never the outer [bound] — so a nested decode can
           never read past either its own key blob or the overall input.
           [kblob_end <= bound] unconditionally: [read_len_prefix] just
           above already validated [kblob_len] against [bound] (the
           "claimed length exceeds remaining input" check), which is
           exactly what guarantees [pos + kblob_len (= kblob_end) <=
           bound] before [kblob_end] is ever used as a bound itself — no
           copy, no allocation proportional to nesting depth. Requiring the
           nested decode to land on exactly
           [kblob_end] (not merely `<= kblob_end`) is what makes this
           equivalent to the old "decode the blob and require it fully
           consumed" check: trailing garbage inside a key blob (a key blob
           claiming more bytes than one complete encoded value needs) is
           exactly as invalid as trailing garbage after the top-level input
           (see [canonical_decode] below). *)
        let kblob_len, pos = read_len_prefix s pos ~bound ~what:"map key blob" in
        let kblob_start = pos in
        let kblob_end = pos + kblob_len in
        (* M8 (task-6 review): unlike the Record case just above, a Map key's raw bytes are
           an arbitrary, generally non-printable encoded blob - there's no analogue of the
           Record error's `%S` to put in the message. Report the entry's 0-based index and
           its byte offset into the input instead, so a real cross-replica ordering
           disagreement is locatable from a single log line rather than only "a map entry,
           somewhere". *)
        let entry_index = count - i in
        (match prev_kblob with
         | Some (prev_start, prev_len) ->
           let c = compare_byte_range s ~a_pos:prev_start ~a_len:prev_len ~b_pos:kblob_start ~b_len:kblob_len in
           if c = 0 then
             invalid_arg
               (Printf.sprintf "canonical_decode: duplicate map key (entry index %d, byte offset %d)" entry_index
                  kblob_start)
           else if c > 0 then
             invalid_arg
               (Printf.sprintf
                  "canonical_decode: map entries are not in canonical (key-sorted) order (entry index %d, byte \
                   offset %d)"
                  entry_index kblob_start)
         | None -> ());
        let k, kpos = decode_value s kblob_start ~bound:kblob_end ~depth:(depth + 1) ~input_len ~node_count in
        if kpos <> kblob_end then invalid_arg "canonical_decode: trailing bytes after map key value";
        let v, pos = decode_value s kblob_end ~bound ~depth:(depth + 1) ~input_len ~node_count in
        loop (i - 1) pos ((k, v) :: acc) ~prev_kblob:(Some (kblob_start, kblob_len))
    in
    let entries, pos = loop count pos [] ~prev_kblob:None in
    (Map entries, pos)
  else invalid_arg (Printf.sprintf "canonical_decode: unknown tag byte 0x%02x" (Char.code tag))

let canonical_decode s =
  if String.length s = 0 then invalid_arg "canonical_decode: empty input";
  let input_len = String.length s in
  let node_count = ref 0 in
  let v, pos = decode_value s 0 ~bound:input_len ~depth:0 ~input_len ~node_count in
  if pos <> input_len then invalid_arg "canonical_decode: trailing bytes after decoded value";
  v

let content_hash v = Digestif.SHA256.(to_raw_string (digest_string (canonical_encode v)))

let hash_to_hex h = Digestif.SHA256.(to_hex (of_raw_string h))
