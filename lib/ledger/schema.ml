open Riptide

type role = Debit | Credit

type transfer_request = {
  request_id : int64;
  from_account : int64;
  to_account : int64;
  amount : int64;
}

type transfer_leg = {
  transfer_id : int64;
  role : role;
  actor : Envelope.actor_id;
  this_account : int64;
  other_account : int64;
  amount : int64;
}

let requests_merge_key = "ledger.requests"
let account_prefix = "ledger.account."

let account_merge_key (account_id : int64) : string =
  Printf.sprintf "%s%Ld" account_prefix account_id

let is_account_key (mk : string) : bool =
  String.length mk >= String.length account_prefix
  && String.sub mk 0 (String.length account_prefix) = account_prefix

let account_of_merge_key (mk : string) : int64 option =
  if not (is_account_key mk) then None
  else
    let suffix =
      String.sub mk (String.length account_prefix)
        (String.length mk - String.length account_prefix)
    in
    match Int64.of_string_opt suffix with
    (* Re-render and compare, so this is a genuine inverse of [account_merge_key] rather than
       merely compatible with it: "0x10", "+7", "1_0" and "007" all parse as int64 but none is a
       key [account_merge_key] could ever have produced, and treating them as if they were would
       make two different merge_key strings name the same account. *)
    | Some id when account_merge_key id = mk -> Some id
    | Some _ | None -> None

let transfer_idempotency_key (request_id : int64) : string =
  Printf.sprintf "ledger-transfer-%Ld" request_id

(* ---- transfer_request <-> Value.value ---- *)

let role_to_value (r : role) : Value.value =
  match r with
  | Debit -> Value.Sum ("Debit", Value.Scalar (Value.Bool true))
  | Credit -> Value.Sum ("Credit", Value.Scalar (Value.Bool true))

let role_of_value (v : Value.value) : role option =
  match v with
  | Value.Sum ("Debit", Value.Scalar (Value.Bool true)) -> Some Debit
  | Value.Sum ("Credit", Value.Scalar (Value.Bool true)) -> Some Credit
  | _ -> None

let transfer_request_to_value (r : transfer_request) : Value.value =
  Value.Record
    [
      ("request_id", Value.Scalar (Value.Int r.request_id));
      ("from_account", Value.Scalar (Value.Int r.from_account));
      ("to_account", Value.Scalar (Value.Int r.to_account));
      ("amount", Value.Scalar (Value.Int r.amount));
    ]

let field_opt fields name = List.assoc_opt name fields

let transfer_request_of_value (v : Value.value) : transfer_request option =
  match v with
  | Value.Record fields -> (
    match
      ( field_opt fields "request_id",
        field_opt fields "from_account",
        field_opt fields "to_account",
        field_opt fields "amount" )
    with
    | Some (Value.Scalar (Value.Int request_id)), Some (Value.Scalar (Value.Int from_account)),
      Some (Value.Scalar (Value.Int to_account)), Some (Value.Scalar (Value.Int amount)) ->
      Some { request_id; from_account; to_account; amount }
    | _ -> None)
  | _ -> None

(* ---- transfer_leg <-> Value.value ---- *)

let transfer_leg_to_value (l : transfer_leg) : Value.value =
  Value.Record
    [
      ("transfer_id", Value.Scalar (Value.Int l.transfer_id));
      ("role", role_to_value l.role);
      ("actor", Value.Scalar (Value.String l.actor));
      ("this_account", Value.Scalar (Value.Int l.this_account));
      ("other_account", Value.Scalar (Value.Int l.other_account));
      ("amount", Value.Scalar (Value.Int l.amount));
    ]

let transfer_leg_of_value (v : Value.value) : transfer_leg option =
  match v with
  | Value.Record fields -> (
    match
      ( field_opt fields "transfer_id",
        field_opt fields "role",
        field_opt fields "actor",
        field_opt fields "this_account",
        field_opt fields "other_account",
        field_opt fields "amount" )
    with
    | Some (Value.Scalar (Value.Int transfer_id)), Some role_val,
      Some (Value.Scalar (Value.String actor)), Some (Value.Scalar (Value.Int this_account)),
      Some (Value.Scalar (Value.Int other_account)), Some (Value.Scalar (Value.Int amount)) -> (
      match role_of_value role_val with
      | Some role -> Some { transfer_id; role; actor; this_account; other_account; amount }
      | None -> None)
    | _ -> None)
  | _ -> None
