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
  this_account : int64;
  other_account : int64;
  amount : int64;
}

val requests_merge_key : string
val account_merge_key : int64 -> string

val transfer_request_to_value : transfer_request -> Riptide.Value.value
val transfer_request_of_value : Riptide.Value.value -> transfer_request option
val transfer_leg_to_value : transfer_leg -> Riptide.Value.value
val transfer_leg_of_value : Riptide.Value.value -> transfer_leg option
