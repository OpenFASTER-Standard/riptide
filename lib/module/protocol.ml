type state = string
type transition = { from_state : state; on_call : string; to_state : state }
type t = {
  states : state list;
  initial : state;
  transitions : transition list;
}

let create ~states ~initial ~transitions =
  (* Validate initial state is in states *)
  if not (List.mem initial states) then
    raise (Invalid_argument (Printf.sprintf "Protocol.create: initial state \"%s\" not in states" initial));

  (* Validate all transitions reference known states *)
  List.iter (fun t ->
    if not (List.mem t.from_state states) then
      raise (Invalid_argument (Printf.sprintf "Protocol.create: transition from unknown state \"%s\"" t.from_state));
    if not (List.mem t.to_state states) then
      raise (Invalid_argument (Printf.sprintf "Protocol.create: transition to unknown state \"%s\"" t.to_state))
  ) transitions;

  (* Validate nondeterminism - no two transitions can have the same (from_state, on_call) pair *)
  let seen = ref [] in
  List.iter (fun t ->
    let key = (t.from_state, t.on_call) in
    if List.mem key !seen then
      raise (Invalid_argument (Printf.sprintf "Protocol.create: state \"%s\" already has a transition on call \"%s\"" t.from_state t.on_call));
    seen := key :: !seen
  ) transitions;

  { states; initial; transitions }

type checker = {
  protocol : t;
  current : state;
}

let start p = { protocol = p; current = p.initial }

let step checker ~call =
  let transitions = checker.protocol.transitions in
  match List.find_opt (fun t -> t.from_state = checker.current && t.on_call = call) transitions with
  | Some t -> Ok { checker with current = t.to_state }
  | None -> Error (Printf.sprintf "No transition from state \"%s\" on call \"%s\"" checker.current call)

let current_state checker = checker.current
