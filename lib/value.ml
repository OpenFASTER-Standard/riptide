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

let content_hash v = Digestif.SHA256.(to_raw_string (digest_string (canonical_encode v)))

let hash_to_hex h = Digestif.SHA256.(to_hex (of_raw_string h))
