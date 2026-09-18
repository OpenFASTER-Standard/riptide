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

let rec encode_into buf v =
  match v with
  | Scalar (Bool b) ->
    Buffer.add_char buf tag_scalar_bool;
    Buffer.add_char buf (if b then '\x01' else '\x00')
  | Scalar (Int i) ->
    Buffer.add_char buf tag_scalar_int;
    for shift = 56 downto 0 do
      if shift mod 8 = 0 then
        Buffer.add_char buf (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical i shift) 0xffL)))
    done
  | Scalar (Float f) ->
    Buffer.add_char buf tag_scalar_float;
    let bits = Int64.bits_of_float f in
    for shift = 56 downto 0 do
      if shift mod 8 = 0 then
        Buffer.add_char buf (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical bits shift) 0xffL)))
    done
  | Scalar (String s) ->
    Buffer.add_char buf tag_scalar_string;
    buf_add_len_prefixed buf s
  | Scalar (Bytes b) ->
    Buffer.add_char buf tag_scalar_bytes;
    buf_add_len_prefixed buf b
  | Record fields ->
    Buffer.add_char buf tag_record;
    let sorted = List.stable_sort (fun (k1, _) (k2, _) -> String.compare k1 k2) fields in
    let count = List.length sorted in
    for i = 7 downto 0 do
      Buffer.add_char buf (Char.chr ((count lsr (8 * i)) land 0xff))
    done;
    List.iter
      (fun (k, v) ->
         buf_add_len_prefixed buf k;
         encode_into buf v)
      sorted
  | Sum (tag, v) ->
    Buffer.add_char buf tag_sum;
    buf_add_len_prefixed buf tag;
    encode_into buf v
  | Sequence items ->
    Buffer.add_char buf tag_sequence;
    let count = List.length items in
    for i = 7 downto 0 do
      Buffer.add_char buf (Char.chr ((count lsr (8 * i)) land 0xff))
    done;
    List.iter (encode_into buf) items
  | Map entries ->
    Buffer.add_char buf tag_map;
    let encoded_entries = List.map (fun (k, v) ->
        let kb = Buffer.create 16 in
        encode_into kb k;
        (Buffer.contents kb, v))
        entries
    in
    let sorted = List.stable_sort (fun (k1, _) (k2, _) -> String.compare k1 k2) encoded_entries in
    let count = List.length sorted in
    for i = 7 downto 0 do
      Buffer.add_char buf (Char.chr ((count lsr (8 * i)) land 0xff))
    done;
    List.iter
      (fun (kbytes, v) ->
         buf_add_len_prefixed buf kbytes;
         encode_into buf v)
      sorted

let canonical_encode v =
  let buf = Buffer.create 64 in
  encode_into buf v;
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

(* Reads an 8-byte big-endian length/count prefix at [pos] and validates it
   against the bytes actually remaining in [s] after the prefix itself —
   this one check covers both "truncated prefix" (fewer than 8 bytes left
   to read the prefix from) and "claimed length/count exceeds remaining
   input" (the prefix decodes fine but names more bytes/entries than [s]
   could possibly contain). [what] is used only to make the raised message
   descriptive (e.g. "string length", "record field count").
   The intermediate accumulation is done in [Int64] specifically so a
   maliciously large 8-byte prefix (top bit set, or otherwise unrepresentable
   as a native non-negative [int]) is rejected by the [v64 < 0L] / [v64 >
   Int64.of_int remaining] comparisons themselves, rather than silently
   wrapping into some smaller (and wrong) native [int] first. *)
let read_len_prefix s pos ~what =
  let n = String.length s in
  if pos + 8 > n then invalid_arg (Printf.sprintf "canonical_decode: truncated %s length prefix" what);
  let v64 = ref 0L in
  for i = 0 to 7 do
    v64 := Int64.logor (Int64.shift_left !v64 8) (Int64.of_int (Char.code s.[pos + i]))
  done;
  let pos = pos + 8 in
  let remaining = n - pos in
  if !v64 < 0L || !v64 > Int64.of_int remaining then
    invalid_arg (Printf.sprintf "canonical_decode: %s length %Ld exceeds remaining input (%d bytes)" what !v64 remaining);
  (Int64.to_int !v64, pos)

(* Reads a raw 8-byte big-endian [int64] payload (used for [Int] and
   [Float], whose bit pattern is stored verbatim per [encode_into]). *)
let read_i64_payload s pos ~what =
  let n = String.length s in
  if pos + 8 > n then invalid_arg (Printf.sprintf "canonical_decode: truncated %s" what);
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

let rec decode_value s pos =
  let n = String.length s in
  if pos >= n then invalid_arg "canonical_decode: unexpected end of input (expected a value tag byte)";
  let tag = s.[pos] in
  let pos = pos + 1 in
  if tag = tag_scalar_bool then begin
    if pos >= n then invalid_arg "canonical_decode: truncated bool payload";
    let v =
      match s.[pos] with
      | '\x00' -> false
      | '\x01' -> true
      | c -> invalid_arg (Printf.sprintf "canonical_decode: invalid bool byte 0x%02x" (Char.code c))
    in
    (Scalar (Bool v), pos + 1)
  end
  else if tag = tag_scalar_int then
    let i, pos = read_i64_payload s pos ~what:"int payload" in
    (Scalar (Int i), pos)
  else if tag = tag_scalar_float then
    let bits, pos = read_i64_payload s pos ~what:"float payload" in
    (Scalar (Float (Int64.float_of_bits bits)), pos)
  else if tag = tag_scalar_string then
    let len, pos = read_len_prefix s pos ~what:"string" in
    let str, pos = read_bytes_exact s pos len in
    (Scalar (String str), pos)
  else if tag = tag_scalar_bytes then
    let len, pos = read_len_prefix s pos ~what:"bytes" in
    let b, pos = read_bytes_exact s pos len in
    (Scalar (Bytes b), pos)
  else if tag = tag_record then
    let count, pos = read_len_prefix s pos ~what:"record field count" in
    let rec loop i pos acc =
      if i = 0 then (List.rev acc, pos)
      else
        let klen, pos = read_len_prefix s pos ~what:"record field key" in
        let k, pos = read_bytes_exact s pos klen in
        let v, pos = decode_value s pos in
        loop (i - 1) pos ((k, v) :: acc)
    in
    let fields, pos = loop count pos [] in
    (Record fields, pos)
  else if tag = tag_sum then
    let tlen, pos = read_len_prefix s pos ~what:"sum tag" in
    let t, pos = read_bytes_exact s pos tlen in
    let v, pos = decode_value s pos in
    (Sum (t, v), pos)
  else if tag = tag_sequence then
    let count, pos = read_len_prefix s pos ~what:"sequence element count" in
    let rec loop i pos acc =
      if i = 0 then (List.rev acc, pos)
      else
        let v, pos = decode_value s pos in
        loop (i - 1) pos (v :: acc)
    in
    let items, pos = loop count pos [] in
    (Sequence items, pos)
  else if tag = tag_map then
    let count, pos = read_len_prefix s pos ~what:"map entry count" in
    let rec loop i pos acc =
      if i = 0 then (List.rev acc, pos)
      else
        (* The asymmetry vs. Record: a Map entry's key is stored as a
           length-prefixed blob containing the key's OWN recursively
           encoded bytes (see [encode_into]'s [Map] case), not encoded
           inline the way a Record field name is. So: read a
           length-prefixed blob from the OUTER stream, then recursively
           decode THAT blob (from position 0, requiring it to be consumed
           exactly) back into a [value] — never decode the key directly
           from the outer stream. *)
        let kblob_len, pos = read_len_prefix s pos ~what:"map key blob" in
        let kblob, pos = read_bytes_exact s pos kblob_len in
        let k = decode_value_exact kblob in
        let v, pos = decode_value s pos in
        loop (i - 1) pos ((k, v) :: acc)
    in
    let entries, pos = loop count pos [] in
    (Map entries, pos)
  else invalid_arg (Printf.sprintf "canonical_decode: unknown tag byte 0x%02x" (Char.code tag))

(* Decodes a complete value from [blob] and requires every byte of [blob]
   to be consumed — used for Map keys, whose blob must contain exactly one
   recursively-encoded value and nothing else (trailing garbage inside a
   key blob is exactly as invalid as trailing garbage after the top-level
   input, see [canonical_decode] below). *)
and decode_value_exact blob =
  let v, pos = decode_value blob 0 in
  if pos <> String.length blob then invalid_arg "canonical_decode: trailing bytes after map key value";
  v

let canonical_decode s =
  if String.length s = 0 then invalid_arg "canonical_decode: empty input";
  let v, pos = decode_value s 0 in
  if pos <> String.length s then invalid_arg "canonical_decode: trailing bytes after decoded value";
  v

let content_hash v = Digestif.SHA256.(to_raw_string (digest_string (canonical_encode v)))

let hash_to_hex h = Digestif.SHA256.(to_hex (of_raw_string h))
