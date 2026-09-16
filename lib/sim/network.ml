type peer_id = string
type 'msg t = (peer_id, 'msg Eio.Stream.t) Hashtbl.t

let create () : 'msg t = Hashtbl.create 8

let inbox_of net id =
  match Hashtbl.find_opt net id with
  | Some inbox -> inbox
  | None -> invalid_arg (Printf.sprintf "Network: peer %S is not registered" id)

let register net id =
  if Hashtbl.mem net id then invalid_arg (Printf.sprintf "Network: peer %S already registered" id);
  Hashtbl.add net id (Eio.Stream.create max_int)

let send net ~from_:_ ~to_ msg = Eio.Stream.add (inbox_of net to_) msg
let receive net id = Eio.Stream.take (inbox_of net id)
let receive_nonblocking net id = Eio.Stream.take_nonblocking (inbox_of net id)
