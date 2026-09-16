type t = Random.State.t

let create seed = Random.State.make [| seed |]
let int t bound = Random.State.int t bound
let float t bound = Random.State.float t bound

let bool t p =
  let p = if p < 0.0 then 0.0 else if p > 1.0 then 1.0 else p in
  Random.State.float t 1.0 < p
