open Riptide

(* Field lists transcribed verbatim from spec/tla/VSR.tla's Send/Broadcast record literals
   -- see message.mli for the full cross-check against that file, including why [dest] is
   deliberately omitted from every constructor. *)
type t =
  | Prepare of { view : int; n : int; v : Value.value; k : int }
  | Prepare_ok of { view : int; n : int; i : int }
  | Start_view_change of { v : int; i : int }
  | Do_view_change of {
      v : int;
      entries : (int * Value.value) list;
      nacks : int list;
      last_normal_view : int;
      n : int;
      k : int;
      i : int;
    }
  | Start_view of { v : int; log : Value.value list; n : int; k : int }

exception Malformed_message of string

(* ---- wire tags (message.mli documents these as the actual, stable wire format) ---- *)
let tag_prepare = "Prepare"
let tag_prepare_ok = "PrepareOk"
let tag_start_view_change = "StartViewChange"
let tag_do_view_change = "DoViewChange"
let tag_start_view = "StartView"

(* ---- t -> Value.value ---- *)

let int_field name i : string * Value.value = (name, Value.Scalar (Value.Int (Int64.of_int i)))
let log_field log : string * Value.value = ("log", Value.Sequence log)

(* [DoViewChange]'s own [entries] field is a PARTIAL FUNCTION in the spec (VSR.tla:381-382,
   [ReadableEntries(r)], VSR.tla:170) -- defined exactly on the op-numbers the sender can actually
   READ, with corrupt slots simply absent from its domain. A [Value.Sequence] of values cannot
   express that (a sequence's domain is always a contiguous [1..Len]), so each entry carries its
   own op-number: [Sequence [ Record [ o; v ]; ... ]], the wire shape of TLA+'s own
   [[ o \in {...} |-> ...]]. *)
let entries_field entries : string * Value.value =
  ( "entries",
    Value.Sequence
      (List.map (fun (o, value) -> Value.Record [ int_field "o" o; ("v", value) ]) entries) )

let int_list_field name l : string * Value.value =
  (name, Value.Sequence (List.map (fun i -> Value.Scalar (Value.Int (Int64.of_int i))) l))

let to_value (t : t) : Value.value =
  match t with
  | Prepare { view; n; v; k } ->
    Value.Sum (tag_prepare, Value.Record [ int_field "view" view; int_field "n" n; ("v", v); int_field "k" k ])
  | Prepare_ok { view; n; i } ->
    Value.Sum (tag_prepare_ok, Value.Record [ int_field "view" view; int_field "n" n; int_field "i" i ])
  | Start_view_change { v; i } ->
    Value.Sum (tag_start_view_change, Value.Record [ int_field "v" v; int_field "i" i ])
  | Do_view_change { v; entries; nacks; last_normal_view; n; k; i } ->
    Value.Sum
      ( tag_do_view_change,
        Value.Record
          [
            int_field "v" v;
            entries_field entries;
            int_list_field "nacks" nacks;
            int_field "last_normal_view" last_normal_view;
            int_field "n" n;
            int_field "k" k;
            int_field "i" i;
          ] )
  | Start_view { v; log; n; k } ->
    Value.Sum
      (tag_start_view, Value.Record [ int_field "v" v; log_field log; int_field "n" n; int_field "k" k ])

let encode (t : t) : string = Value.canonical_encode (to_value t)

(* ---- Value.value -> t ---- *)

let field_exn tag fields name : Value.value =
  match List.assoc_opt name fields with
  | Some v -> v
  | None -> raise (Malformed_message (Printf.sprintf "%s: missing field %S" tag name))

let int_of_field tag fields name : int =
  match field_exn tag fields name with
  | Value.Scalar (Value.Int i) -> Int64.to_int i
  | _ -> raise (Malformed_message (Printf.sprintf "%s: field %S is not an Int scalar" tag name))

let value_list_of_field tag fields name : Value.value list =
  match field_exn tag fields name with
  | Value.Sequence l -> l
  | _ -> raise (Malformed_message (Printf.sprintf "%s: field %S is not a Sequence" tag name))

let int_list_of_field tag fields name : int list =
  List.map
    (fun v ->
      match v with
      | Value.Scalar (Value.Int i) -> Int64.to_int i
      | _ ->
        raise (Malformed_message (Printf.sprintf "%s: field %S holds a non-Int element" tag name)))
    (value_list_of_field tag fields name)

(* The inverse of [entries_field] above. Note what is NOT checked here: nothing about whether the
   op-numbers are in range, ordered, unique, or consistent with the message's own [n]. This module
   validates SHAPE only -- [Replica.handle_do_view_change] carries every protocol-level bound, per
   the established split documented on {!decode}. *)
let entries_of_field tag fields name : (int * Value.value) list =
  List.map
    (fun v ->
      match v with
      | Value.Record entry_fields ->
        (int_of_field tag entry_fields "o", field_exn tag entry_fields "v")
      | _ ->
        raise
          (Malformed_message (Printf.sprintf "%s: field %S holds a non-Record element" tag name)))
    (value_list_of_field tag fields name)

let of_value (v : Value.value) : t =
  match v with
  | Value.Sum (tag, inner) ->
    let fields =
      match inner with
      | Value.Record fields -> fields
      | _ -> raise (Malformed_message (Printf.sprintf "%s: expected a Record body" tag))
    in
    if tag = tag_prepare then
      Prepare
        {
          view = int_of_field tag fields "view";
          n = int_of_field tag fields "n";
          v = field_exn tag fields "v";
          k = int_of_field tag fields "k";
        }
    else if tag = tag_prepare_ok then
      Prepare_ok
        { view = int_of_field tag fields "view"; n = int_of_field tag fields "n"; i = int_of_field tag fields "i" }
    else if tag = tag_start_view_change then
      Start_view_change { v = int_of_field tag fields "v"; i = int_of_field tag fields "i" }
    else if tag = tag_do_view_change then
      Do_view_change
        {
          v = int_of_field tag fields "v";
          entries = entries_of_field tag fields "entries";
          nacks = int_list_of_field tag fields "nacks";
          last_normal_view = int_of_field tag fields "last_normal_view";
          n = int_of_field tag fields "n";
          k = int_of_field tag fields "k";
          i = int_of_field tag fields "i";
        }
    else if tag = tag_start_view then
      Start_view
        {
          v = int_of_field tag fields "v";
          log = value_list_of_field tag fields "log";
          n = int_of_field tag fields "n";
          k = int_of_field tag fields "k";
        }
    else raise (Malformed_message (Printf.sprintf "unknown message tag %S" tag))
  | _ -> raise (Malformed_message "expected a Sum value at the top level")

let decode (s : string) : t =
  let v = try Value.canonical_decode s with Invalid_argument msg -> raise (Malformed_message msg) in
  of_value v
