type log = { mutable entries : Envelope.envelope list (* reverse order: newest first *); mutable count : int }

let create () = { entries = []; count = 0 }

let append log ~actor ~causation ~correlation ~payload =
  let predecessor_hash =
    match log.entries with
    | [] -> Envelope.genesis_marker
    | latest :: _ -> Envelope.content_hash latest
  in
  log.count <- log.count + 1;
  let sequence = Int64.of_int log.count in
  let envelope : Envelope.envelope =
    { actor; causation; correlation; predecessor_hash; sequence; payload }
  in
  log.entries <- envelope :: log.entries;
  envelope

let to_list log = List.rev log.entries

let verify_chain_list entries =
  let rec check expected_pred = function
    | [] -> true
    | (e : Envelope.envelope) :: rest ->
      if e.predecessor_hash <> expected_pred then false
      else check (Envelope.content_hash e) rest
  in
  check Envelope.genesis_marker entries

let verify_chain log = verify_chain_list (to_list log)
