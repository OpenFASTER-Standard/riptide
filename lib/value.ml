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
   every value encoded, not just ones with deep Map-key chains. Measured
   live on an ordinary 2-million-element [Sequence] of [Bool] (3.8MB
   encoded, no [Map] anywhere in it): live heap for the value tree alone
   was 107.5 MiB, but peak heap during [canonical_encode] reached 237.2
   MiB - a +117% regression on the exact memory axis this task exists to
   improve, paid by every caller, unconditionally (audit finding I1).

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

let rec encode_into buf (v : value) =
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
    let sorted = List.stable_sort (fun (k1, _) (k2, _) -> String.compare k1 k2) fields in
    write_u64_be buf (List.length sorted);
    List.iter
      (fun (k, v) ->
         buf_add_len_prefixed buf k;
         encode_into buf v)
      sorted
  | Sum (tag, v) ->
    Wbuf.add_char buf tag_sum;
    buf_add_len_prefixed buf tag;
    encode_into buf v
  | Sequence items ->
    Wbuf.add_char buf tag_sequence;
    write_u64_be buf (List.length items);
    List.iter (encode_into buf) items
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
       encode_into buf k;
       Wbuf.patch_u64_be buf len_off (Wbuf.length buf - key_start);
       encode_into buf v
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
          nesting level - see
          docs/superpowers/plans/2026-09-29-audit-remediation.md Task 8,
          which threads a depth counter through BOTH [decode_value] and
          [encode_into] (capping nesting at 1000) and is the intended
          mitigation for this residual. Do not silently narrow Task 8's
          scope to [decode_value] only. *)
       let encoded_entries = List.map (fun (k, v) ->
           let kb = Wbuf.create 64 in
           encode_into kb k;
           (Wbuf.contents kb, v))
           entries
       in
       let sorted = List.stable_sort (fun (k1, _) (k2, _) -> String.compare k1 k2) encoded_entries in
       List.iter
         (fun (kbytes, v) ->
            buf_add_len_prefixed buf kbytes;
            encode_into buf v)
         sorted)

let canonical_encode v =
  let buf = Wbuf.create 256 in
  encode_into buf v;
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

let rec decode_value s pos ~bound =
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
    let rec loop i pos acc =
      if i = 0 then (List.rev acc, pos)
      else
        let klen, pos = read_len_prefix s pos ~bound ~what:"record field key" in
        let k, pos = read_bytes_exact s pos klen in
        let v, pos = decode_value s pos ~bound in
        loop (i - 1) pos ((k, v) :: acc)
    in
    let fields, pos = loop count pos [] in
    (Record fields, pos)
  else if tag = tag_sum then
    let tlen, pos = read_len_prefix s pos ~bound ~what:"sum tag" in
    let t, pos = read_bytes_exact s pos tlen in
    let v, pos = decode_value s pos ~bound in
    (Sum (t, v), pos)
  else if tag = tag_sequence then
    let count, pos = read_len_prefix s pos ~bound ~what:"sequence element count" in
    let rec loop i pos acc =
      if i = 0 then (List.rev acc, pos)
      else
        let v, pos = decode_value s pos ~bound in
        loop (i - 1) pos (v :: acc)
    in
    let items, pos = loop count pos [] in
    (Sequence items, pos)
  else if tag = tag_map then
    let count, pos = read_len_prefix s pos ~bound ~what:"map entry count" in
    let rec loop i pos acc =
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
        let kblob_end = pos + kblob_len in
        let k, kpos = decode_value s pos ~bound:kblob_end in
        if kpos <> kblob_end then invalid_arg "canonical_decode: trailing bytes after map key value";
        let v, pos = decode_value s kblob_end ~bound in
        loop (i - 1) pos ((k, v) :: acc)
    in
    let entries, pos = loop count pos [] in
    (Map entries, pos)
  else invalid_arg (Printf.sprintf "canonical_decode: unknown tag byte 0x%02x" (Char.code tag))

let canonical_decode s =
  if String.length s = 0 then invalid_arg "canonical_decode: empty input";
  let v, pos = decode_value s 0 ~bound:(String.length s) in
  if pos <> String.length s then invalid_arg "canonical_decode: trailing bytes after decoded value";
  v

let content_hash v = Digestif.SHA256.(to_raw_string (digest_string (canonical_encode v)))

let hash_to_hex h = Digestif.SHA256.(to_hex (of_raw_string h))
