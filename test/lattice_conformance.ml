(* test/lattice_conformance.ml

   The [Lattice_intf.S] analogue of [test_transport_shared.ml]/[test_storage_shared.ml]'s own
   pattern: a reusable, functor-free test body that never references a concrete lattice instance
   by name — it only ever sees an abstract [(module L : Lattice_intf.S with type t = 'a)] plus a
   QCheck arbitrary for that same ['a] — and produces the four join-semilattice law checks
   (commutativity, associativity, idempotency, and [bottom] as identity) as real, runnable
   Alcotest test cases. Any concrete instance (e.g. [Last_write_wins], or a future lattice type)
   is conformance-checked by simply calling [tests] against it, the same way
   [Test_storage_shared.Make_storage_tests] is instantiated per storage backend. *)

let tests (type a) (module L : Riptide_lattice.Lattice_intf.S with type t = a)
    (arb : a QCheck.arbitrary) (label : string) : unit Alcotest.test_case list =
  [
    ( label ^ ": join is commutative", `Quick,
      fun () ->
        QCheck.Test.check_exn
          (QCheck.Test.make ~count:200 (QCheck.pair arb arb) (fun (a, b) ->
               L.join a b = L.join b a)) );
    ( label ^ ": join is associative", `Quick,
      fun () ->
        QCheck.Test.check_exn
          (QCheck.Test.make ~count:200 (QCheck.triple arb arb arb) (fun (a, b, c) ->
               L.join (L.join a b) c = L.join a (L.join b c))) );
    ( label ^ ": join is idempotent", `Quick,
      fun () ->
        QCheck.Test.check_exn
          (QCheck.Test.make ~count:200 arb (fun a -> L.join a a = a)) );
    ( label ^ ": bottom is the join identity", `Quick,
      fun () ->
        QCheck.Test.check_exn
          (QCheck.Test.make ~count:200 arb (fun a -> L.join L.bottom a = a)) );
  ]
