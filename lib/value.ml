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

let buf_add_len_prefixed buf s =
  let len = String.length s in
  for i = 7 downto 0 do
    Buffer.add_char buf (Char.chr ((len lsr (8 * i)) land 0xff))
  done;
  Buffer.add_string buf s

let tag_scalar_bool = '\x00'
let tag_scalar_int = '\x01'
let tag_scalar_float = '\x02'
let tag_scalar_string = '\x03'
let tag_scalar_bytes = '\x04'
let tag_record = '\x05'
let tag_sum = '\x06'
let tag_sequence = '\x07'
let tag_map = '\x08'

let write_u64_be buf (n : int) =
  for i = 7 downto 0 do
    Buffer.add_char buf (Char.chr ((n lsr (8 * i)) land 0xff))
  done

(* An auxiliary tree, shaped exactly like [value], but where every node
   additionally carries [size]: the exact byte length [encode_into] below
   would produce for that node's own subtree. [size_value] computes this
   bottom-up in a single pass over the input [value] - each node visited,
   and its size computed from its already-computed children's sizes, EXACTLY
   ONCE - and [encode_into] then reads [size] as a plain field lookup
   wherever it needs a subtree's length, rather than ever re-deriving it.

   This exists specifically so [encode_into]'s [Map] case (see there) can
   write a single-entry key's length prefix without first materializing
   that key's bytes into a throwaway buffer just to measure them. An
   earlier version of this fix used a plain [encoded_size : value -> int]
   function called directly from [encode_into] instead of this precomputed
   tree - that was still wrong in the same way the original bug was: called
   once per nesting level on that level's (already large) subtree, it
   re-walked the entire subtree from scratch at every level, which is
   O(depth) work repeated at each of O(depth) levels - O(depth^2) again,
   just moved from byte-copying into size-recomputation. Precomputing once,
   bottom-up, over the whole tree is the actual fix: every node's size is
   derived from its children's sizes in O(1), so the whole pass is
   O(total nodes), independent of how deep any one chain of nesting goes. *)
type sized_value = { size : int; shape : sized_shape }

and sized_shape =
  | SScalar of scalar
  | SRecord of (string * sized_value) list
  | SSum of string * sized_value
  | SSequence of sized_value list
  | SMap of (sized_value * sized_value) list

let rec size_value (v : value) : sized_value =
  match v with
  | Scalar s ->
    let size =
      match s with
      | Bool _ -> 2
      | Int _ | Float _ -> 9
      | String s -> 9 + String.length s
      | Bytes b -> 9 + String.length b
    in
    { size; shape = SScalar s }
  | Record fields ->
    let sized = List.map (fun (k, v) -> (k, size_value v)) fields in
    let size = 9 + List.fold_left (fun acc (k, sv) -> acc + 8 + String.length k + sv.size) 0 sized in
    { size; shape = SRecord sized }
  | Sum (tag, v) ->
    let sv = size_value v in
    { size = 9 + String.length tag + sv.size; shape = SSum (tag, sv) }
  | Sequence items ->
    let sized = List.map size_value items in
    let size = 9 + List.fold_left (fun acc sv -> acc + sv.size) 0 sized in
    { size; shape = SSequence sized }
  | Map entries ->
    let sized = List.map (fun (k, v) -> (size_value k, size_value v)) entries in
    let size = 9 + List.fold_left (fun acc (sk, sv) -> acc + 8 + sk.size + sv.size) 0 sized in
    { size; shape = SMap sized }

let rec encode_into buf (sv : sized_value) =
  match sv.shape with
  | SScalar (Bool b) ->
    Buffer.add_char buf tag_scalar_bool;
    Buffer.add_char buf (if b then '\x01' else '\x00')
  | SScalar (Int i) ->
    Buffer.add_char buf tag_scalar_int;
    for shift = 56 downto 0 do
      if shift mod 8 = 0 then
        Buffer.add_char buf (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical i shift) 0xffL)))
    done
  | SScalar (Float f) ->
    Buffer.add_char buf tag_scalar_float;
    let bits = Int64.bits_of_float f in
    for shift = 56 downto 0 do
      if shift mod 8 = 0 then
        Buffer.add_char buf (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical bits shift) 0xffL)))
    done
  | SScalar (String s) ->
    Buffer.add_char buf tag_scalar_string;
    buf_add_len_prefixed buf s
  | SScalar (Bytes b) ->
    Buffer.add_char buf tag_scalar_bytes;
    buf_add_len_prefixed buf b
  | SRecord fields ->
    Buffer.add_char buf tag_record;
    let sorted = List.stable_sort (fun (k1, _) (k2, _) -> String.compare k1 k2) fields in
    write_u64_be buf (List.length sorted);
    List.iter
      (fun (k, sv) ->
         buf_add_len_prefixed buf k;
         encode_into buf sv)
      sorted
  | SSum (tag, sv) ->
    Buffer.add_char buf tag_sum;
    buf_add_len_prefixed buf tag;
    encode_into buf sv
  | SSequence items ->
    Buffer.add_char buf tag_sequence;
    write_u64_be buf (List.length items);
    List.iter (encode_into buf) items
  | SMap entries ->
    Buffer.add_char buf tag_map;
    write_u64_be buf (List.length entries);
    (match entries with
     | [] -> ()
     | [ (sk, sv) ] ->
       (* Exactly one entry: there is nothing to sort (a single-element
          order is already "sorted" by definition), so this key can be
          written straight into [buf] - length prefix from [sk.size]
          (already computed by [size_value], a plain field read, no bytes
          touched here), then the key's own bytes via a direct
          [encode_into buf sk] - instead of the general multi-entry path
          below, which must materialize full key bytes into a throwaway
          per-entry buffer to compare them. That materialize-then-discard
          buffer is exactly the shape that turned quadratic with nesting
          depth for a chain of single-entry Map keys (each level's *entire*
          already-built accumulated bytes gets copied out via
          [Buffer.contents] and copied in again via [Buffer.add_string] at
          every level above it - the same doubling that made
          [decode_value]'s old [String.sub]-and-recurse-into-the-copy
          approach quadratic, just on the write side instead of the read
          side). Writing directly here means every byte of a deep
          single-entry chain is written to its final position exactly
          once, giving O(depth) instead of O(depth^2). *)
       write_u64_be buf sk.size;
       encode_into buf sk;
       encode_into buf sv
     | _ :: _ :: _ ->
       (* Two or more entries genuinely need their full encoded key bytes to
          determine sort order, so this path still materializes each key
          via its own buffer - that cost is bounded by the sibling keys' own
          sizes at this one level, not compounded across nesting depth,
          since it only runs once per Map node reached, not once per
          ancestor above every node. *)
       let encoded_entries = List.map (fun (sk, sv) ->
           let kb = Buffer.create sk.size in
           encode_into kb sk;
           (Buffer.contents kb, sv))
           entries
       in
       let sorted = List.stable_sort (fun (k1, _) (k2, _) -> String.compare k1 k2) encoded_entries in
       List.iter
         (fun (kbytes, sv) ->
            buf_add_len_prefixed buf kbytes;
            encode_into buf sv)
         sorted)

let canonical_encode v =
  let sv = size_value v in
  let buf = Buffer.create sv.size in
  encode_into buf sv;
  Buffer.contents buf

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
   already validated by [read_len_prefix] against the same [s], so
   [pos + len <= String.length s] is already guaranteed here — no separate
   check is needed to stay in bounds. *)
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
           [kblob_end] (never bound - the tighter of the two, so a nested
           decode can never read past either its own key blob or the
           overall input) — no copy, no allocation proportional to nesting
           depth. Requiring the nested decode to land on exactly
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
