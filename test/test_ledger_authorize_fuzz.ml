(* Task 6, subtask 2+5's own fuzz-testing half of the design spec's Decision 1 (see
   docs/superpowers/specs/2026-10-01-layer2-ledger-module-design.md). This module is the first
   real policy Batch_commit's authorization checkpoint has ever carried -- Decision 1 splits its
   job into two genuinely different guarantees, and this file proves both empirically, the same
   way test_batch_commit_authorization_fuzz.ml proves the general checkpoint mechanism:

   1. Authorize-level (what the checkpoint alone can enforce): a SINGLE write, well-formed or
      deliberately malformed, is proposed in isolation and must never reach the committed log if
      Authorize.authorize denies it -- regardless of how that write was constructed, including
      directly, bypassing Legs entirely. This is the "cannot be violated by any sequence of
      valid-looking module operations" bar Decision 1 says the checkpoint alone is responsible for.
   2. Construction-level (what the checkpoint alone CANNOT enforce, and must instead be guaranteed
      by construction): Legs.legs_of_bytes, fed arbitrary/adversarial bytes, must always produce
      either an Error or exactly two legs that are a genuine, balancing pair -- same transfer_id,
      opposite signed deltas, distinct accounts, each this_account/other_account the mirror of the
      other's. Fuzzing the construction code directly (not just inspecting it) is what Decision 1's
      own Testing strategy section calls out as the way to verify this empirically.

   Three further named tests (not fuzzed) pin the exact Review Focus items this task owns: a
   self-transfer request's legs get denied, a non-positive-amount leg gets denied, and a
   DIRECTLY-constructed (not Legs-originated) but individually well-formed-looking leg write is
   still correctly denied when it's missing its sibling in the same batch -- i.e. "looks fine in
   isolation" is not the same as "actually a well-formed, self-certifying single write", and
   authorize's own checks (not just whole-pair balancing) still gate it. *)
open Riptide_ledger

let () = Mirage_crypto_rng_unix.use_default ()

(* Same create_solo/fake_event_id pattern as test_batch_commit_authorization_fuzz.ml: a
   replica_count = 1, f = 0 replica commits synchronously, no network/quorum needed for a property
   that is purely about the authorization checkpoint's own decision. *)
let create_solo () =
  let send ~to_:_ (_ : string) = () in
  Riptide_vsr.Replica.create ~storage:(Riptide_vsr.Replica.volatile_storage ()) ~my_id:1
    ~replica_count:1 ~svc_limit:3 ~send ()

let fake_event_id name = Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String name))

(* ── Property 1: authorize-level ───────────────────────────────────────────────────────────────
   A single transfer_leg, generated directly (never routed through Legs), well-formed or
   deliberately malformed along each of the three axes authorize checks: non-positive amount,
   same-account (this_account = other_account), and a merge_key/account mismatch. Proposed alone,
   through a real Batch_commit.t wired to the real Authorize.authorize. *)

type leg_shape =
  | Well_formed
  | Non_positive_amount
  | Same_account
  | Merge_key_mismatch
  (* Final whole-branch review, finding I2. This generator previously drew accounts from
     -1000..1000 and asserted that WELL-FORMED legs with them commit -- i.e. it actively asserted
     that a negatively-identified account is valid, while the WASM guest could never address one
     (Schema.account_merge_key renders signed, the guest's own decimal routine unsigned), so such an
     account always read balance 0 and always declined. The generator itself is what revealed the
     contradiction. Now that Authorize.authorize constrains ids to be non-negative, well-formed
     cases draw only non-negative accounts and a negative one is a malformed shape in its own
     right. *)
  | Negative_account
  (* Finding I4's own enforcement: a leg's payload-declared actor must match the actor of the write
     carrying it, which is what makes that field trustworthy in a materialize_sink that never sees
     the write's own actor. A leg claiming someone else authored it is malformed. *)
  | Forged_actor

let print_leg_shape = function
  | Well_formed -> "well_formed"
  | Non_positive_amount -> "non_positive_amount"
  | Same_account -> "same_account"
  | Merge_key_mismatch -> "merge_key_mismatch"
  | Negative_account -> "negative_account"
  | Forged_actor -> "forged_actor"

let is_malformed = function
  | Well_formed -> false
  | Non_positive_amount | Same_account | Merge_key_mismatch | Negative_account | Forged_actor ->
    true

type generated_leg = {
  shape : leg_shape;
  transfer_id : int64;
  this_account : int64;
  other_account : int64;
  amount : int64;
  role : Schema.role;
  payload_actor : string;
  wrong_merge_key_account : int64;
      (* used only when shape = Merge_key_mismatch, to build a merge_key naming a DIFFERENT
         account than this_account *)
}

(* The actor every generated leg's own WRITE is proposed under. *)
let write_actor = "fuzz"

let leg_gen : generated_leg QCheck2.Gen.t =
  let open QCheck2.Gen in
  let* shape =
    oneof_weighted
      [
        (3, return Well_formed);
        (1, return Non_positive_amount);
        (1, return Same_account);
        (1, return Merge_key_mismatch);
        (1, return Negative_account);
        (1, return Forged_actor);
      ]
  in
  let* transfer_id = int64 in
  let* this_account_raw = int_range 0 1000 >|= Int64.of_int in
  let* other_account_raw = int_range 0 1000 >|= Int64.of_int in
  let* negative_account = int_range (-1000) (-1) >|= Int64.of_int in
  let* positive_amount = int_range 1 1_000_000 >|= Int64.of_int in
  let* non_positive_amount = int_range (-1_000_000) 0 >|= Int64.of_int in
  let* role = oneof [ return Schema.Debit; return Schema.Credit ] in
  let* wrong_merge_key_account = int_range 0 1000 >|= Int64.of_int in
  let this_account = if shape = Negative_account then negative_account else this_account_raw in
  let other_account =
    (* Make sure the "distinct accounts" baseline holds unless this generated leg is specifically
       the Same_account shape -- otherwise Same_account's distinguishing feature could coincide by
       chance with a Well_formed leg and the property would be testing nothing. *)
    if shape = Same_account then this_account
    else if other_account_raw = this_account then Int64.add other_account_raw 1L
    else other_account_raw
  in
  let amount = match shape with Non_positive_amount -> non_positive_amount | _ -> positive_amount in
  (* The write's own actor is always this; a Forged_actor leg declares a DIFFERENT one in its
     payload, which is the mismatch authorize refuses. *)
  let payload_actor = if shape = Forged_actor then "someone-else" else write_actor in
  return
    {
      shape;
      transfer_id;
      this_account;
      other_account;
      amount;
      role;
      payload_actor;
      wrong_merge_key_account;
    }

let write_of_generated_leg (g : generated_leg) ~actor ~causation ~correlation :
    Riptide_batch_commit.Batch_commit.write =
  let leg =
    Schema.
      {
        transfer_id = g.transfer_id;
        role = g.role;
        actor = g.payload_actor;
        this_account = g.this_account;
        other_account = g.other_account;
        amount = g.amount;
      }
  in
  let merge_key =
    match g.shape with
    | Merge_key_mismatch ->
      (* Deliberately name a DIFFERENT account than this_account -- unless that different account
         happens to coincide with this_account, in which case nudge it so the mismatch is real. *)
      let wrong =
        if g.wrong_merge_key_account = g.this_account then Int64.add g.wrong_merge_key_account 1L
        else g.wrong_merge_key_account
      in
      Some (Schema.account_merge_key wrong)
    | Well_formed | Non_positive_amount | Same_account | Negative_account | Forged_actor ->
      Some (Schema.account_merge_key g.this_account)
  in
  { Riptide_batch_commit.Batch_commit.actor; causation; correlation; payload = Schema.transfer_leg_to_value leg; merge_key }

let print_leg (g : generated_leg) =
  Printf.sprintf "{shape=%s; transfer_id=%Ld; this=%Ld; other=%Ld; amount=%Ld; role=%s; actor=%s}"
    (print_leg_shape g.shape) g.transfer_id g.this_account g.other_account g.amount
    (match g.role with Schema.Debit -> "Debit" | Schema.Credit -> "Credit")
    g.payload_actor

let test_no_malformed_leg_ever_reaches_the_log =
  QCheck2.Test.make ~name:"authorize: no malformed single leg write ever reaches the committed log"
    ~count:200 ~print:print_leg leg_gen (fun g ->
      let replica = create_solo () in
      let handle = Riptide_batch_commit.Batch_commit.create ~replica ~authorize:Authorize.authorize () in
      let event_id = fake_event_id (print_leg g) in
      let w =
        write_of_generated_leg g ~actor:write_actor ~causation:event_id ~correlation:event_id
      in
      Riptide_batch_commit.Batch_commit.propose handle ~idempotency_key:(print_leg g) [ w ];
      let committed = Riptide_batch_commit.Batch_commit.committed_envelopes replica in
      let leg_payloads =
        List.filter_map
          (fun (e : Riptide.Envelope.envelope) -> Schema.transfer_leg_of_value e.payload)
          committed
      in
      (* [role] and [actor] are checked too, not ignored (final whole-branch review, finding M7):
         leaving a field out of this comparison makes the property weaker than it reads -- a
         committed leg differing only in the omitted field would count as "the generated leg
         appeared", so a bug that corrupted exactly that field would pass. *)
      let matches_generated (l : Schema.transfer_leg) =
        l.transfer_id = g.transfer_id && l.role = g.role && l.actor = g.payload_actor
        && l.this_account = g.this_account && l.other_account = g.other_account
        && l.amount = g.amount
      in
      let appeared = List.exists matches_generated leg_payloads in
      if is_malformed g.shape then begin
        if appeared then
          QCheck2.Test.fail_reportf "a malformed leg reached the committed log: %s" (print_leg g);
        true
      end
      else begin
        if not appeared then
          QCheck2.Test.fail_reportf "a well-formed leg did NOT reach the committed log: %s" (print_leg g);
        true
      end)

(* ── Property 2: construction-level ────────────────────────────────────────────────────────────
   Arbitrary/adversarial bytes fed into Legs.legs_of_bytes must always produce either Error, or
   exactly two legs forming a genuine, balancing pair. The generator mixes real, well-formed
   32-byte encoded requests (via Wire.encode_request) with adversarial byte strings: wrong
   lengths (too short, too long, zero-length), and 32-byte-but-content-garbage strings (random
   bytes that happen to decode as SOME request, including ones with negative/zero amounts or
   from_account = to_account, which legs_of_bytes must still turn into a well-paired, if
   business-nonsensical, pair of legs -- "balancing pair" here means role/account/amount
   consistency between the two legs, not that the business transfer itself makes sense; that
   distinction is exactly Decision 1's "authorize cannot and does not check business sense"). *)

let real_encoded_decision_gen : bytes QCheck2.Gen.t =
  let open QCheck2.Gen in
  let* request_id = int64 in
  let* from_account = int64 in
  let* to_account = int64 in
  let* amount = int64 in
  let* accepted = bool in
  return (Wire.encode_decision ~accepted Schema.{ request_id; from_account; to_account; amount })

(* Random bytes at a real [Wire.decision_bytes] length but with a VALID tag byte, so the decode
   genuinely succeeds and the construction code downstream of it is actually exercised on garbage
   content. Without this bucket, almost every 33-byte random string would be thrown out by the tag
   check alone and the property would mostly be testing [decode_decision]'s length/tag guard
   rather than leg construction. *)
let tagged_garbage_gen : bytes QCheck2.Gen.t =
  let open QCheck2.Gen in
  let* accepted = bool in
  let* payload = bytes_size (return Wire.request_bytes) in
  let b = Bytes.make Wire.decision_bytes '\000' in
  Bytes.set b 0 (if accepted then '\001' else '\000');
  Bytes.blit payload 0 b 1 Wire.request_bytes;
  return b

let garbage_bytes_gen : bytes QCheck2.Gen.t =
  let open QCheck2.Gen in
  let* len =
    oneof_weighted
      [
        (2, int_range 0 5);
        (2, int_range 6 32);
        (2, return Wire.decision_bytes);
        (2, int_range 34 80);
      ]
  in
  (* [bytes_size] directly, rather than generating an int list and indexing it with [List.nth]
     inside [String.init] -- that was quadratic in the generated length for no reason (final
     whole-branch review, finding M8). *)
  bytes_size (return len)

let bytes_gen : bytes QCheck2.Gen.t =
  QCheck2.Gen.oneof [ real_encoded_decision_gen; tagged_garbage_gen; garbage_bytes_gen ]

let print_bytes (b : bytes) =
  Printf.sprintf "len=%d [%s]" (Bytes.length b)
    (String.concat " " (List.init (Bytes.length b) (fun i -> Printf.sprintf "%02x" (Char.code (Bytes.get b i)))))

let signed_delta (l : Schema.transfer_leg) = match l.role with Schema.Debit -> Int64.neg l.amount | Schema.Credit -> l.amount

let test_legs_of_bytes_always_produces_nothing_or_a_balanced_pair =
  QCheck2.Test.make
    ~name:"Legs.decision_of_bytes: adversarial bytes always produce Error or a balanced pair"
    ~count:200 ~print:print_bytes bytes_gen (fun b ->
      let actor = "fuzz" in
      let event_id = fake_event_id (print_bytes b) in
      match Legs.decision_of_bytes ~actor ~causation:event_id ~correlation:event_id b with
      | Error _ -> true
      | Ok (_accepted, request, writes) -> (
        (* The request handed back alongside the legs must be the one the legs were actually built
           from -- it is what Accumulator records as a request's final, authoritative content and
           rebuilds the legs from on any later re-proposal, so a mismatch here would let a replay
           move a different amount than the one first decided. *)
        (match writes with
        | w :: _ -> (
          match Schema.transfer_leg_of_value w.Riptide_batch_commit.Batch_commit.payload with
          | Some l when l.transfer_id <> request.Schema.request_id ->
            QCheck2.Test.fail_reportf
              "the returned request (id %Ld) is not the one the legs were built from (id %Ld) for \
               input %s"
              request.Schema.request_id l.transfer_id (print_bytes b)
          | _ -> ())
        | [] -> ());
        if List.length writes <> 2 then
          QCheck2.Test.fail_reportf "legs_of_bytes produced %d writes, not 2, for input %s"
            (List.length writes) (print_bytes b);
        match List.map (fun (w : Riptide_batch_commit.Batch_commit.write) -> Schema.transfer_leg_of_value w.payload) writes with
        | [ Some l1; Some l2 ] ->
          if l1.transfer_id <> l2.transfer_id then
            QCheck2.Test.fail_reportf "legs do not share a transfer_id: %Ld vs %Ld for input %s" l1.transfer_id
              l2.transfer_id (print_bytes b);
          if l1.this_account <> l2.other_account || l2.this_account <> l1.other_account then
            QCheck2.Test.fail_reportf "legs are not mirror-accounted for input %s" (print_bytes b);
          if l1.amount <> l2.amount then
            QCheck2.Test.fail_reportf "legs do not share the same magnitude: %Ld vs %Ld for input %s" l1.amount
              l2.amount (print_bytes b);
          if l1.role = l2.role then
            QCheck2.Test.fail_reportf "both legs have the same role (%s) for input %s"
              (match l1.role with Schema.Debit -> "Debit" | Schema.Credit -> "Credit")
              (print_bytes b);
          let sum = Int64.add (signed_delta l1) (signed_delta l2) in
          if sum <> 0L then
            QCheck2.Test.fail_reportf "legs do not balance to zero (sum=%Ld) for input %s" sum (print_bytes b);
          if l1.actor <> actor || l2.actor <> actor then
            QCheck2.Test.fail_reportf
              "a leg's payload actor is not the one it was constructed under for input %s"
              (print_bytes b);
          let merge_key_ok (w : Riptide_batch_commit.Batch_commit.write) (l : Schema.transfer_leg) =
            w.merge_key = Some (Schema.account_merge_key l.this_account)
            && w.actor = l.actor
          in
          (match writes with
          | [ w1; w2 ] ->
            if not (merge_key_ok w1 l1 && merge_key_ok w2 l2) then
              QCheck2.Test.fail_reportf "a leg's merge_key does not name its own this_account for input %s"
                (print_bytes b)
          | _ -> ());
          true
        | _ ->
          QCheck2.Test.fail_reportf
            "decision_of_bytes produced a payload that doesn't decode as a transfer_leg for input %s"
            (print_bytes b)))

(* ── Three named Review Focus tests ────────────────────────────────────────────────────────── *)

let test_a_self_transfer_request_produces_legs_authorize_denies () =
  let r = Schema.{ request_id = 1L; from_account = 5L; to_account = 5L; amount = 10L } in
  let event_id = fake_event_id "self-transfer" in
  let legs = Legs.legs_of_request ~actor:"t" ~causation:event_id ~correlation:event_id r in
  (* A self-transfer's debit and credit legs are BOTH symmetrically same-account
     (this_account = other_account on each, since from_account = to_account), so each
     independently fails authorize's own `this_account <> other_account` check -- not merely
     "at least one of them" happens to. *)
  Alcotest.(check bool) "both legs are independently denied" true
    (List.for_all
       (fun w -> Authorize.authorize w <> Riptide_batch_commit.Batch_commit.Allow)
       legs)

let test_a_non_positive_amount_leg_is_denied () =
  let leg =
    Schema.
      {
        transfer_id = 1L;
        role = Debit;
        actor = "t";
        this_account = 1L;
        other_account = 2L;
        amount = 0L;
      }
  in
  let event_id = fake_event_id "non-positive-amount" in
  let w =
    Riptide_batch_commit.Batch_commit.
      {
        actor = "t";
        causation = event_id;
        correlation = event_id;
        payload = Schema.transfer_leg_to_value leg;
        merge_key = Some (Schema.account_merge_key 1L);
      }
  in
  Alcotest.(check bool) "denied" true (Authorize.authorize w <> Riptide_batch_commit.Batch_commit.Allow)

let test_a_direct_unpaired_leg_write_is_denied_not_just_a_module_originated_one () =
  (* Construct ONE "well-formed-looking" leg write directly -- never through Legs, so no trusted
     construction code stands between this test and the authorization checkpoint -- and propose
     it ALONE (no sibling leg in the batch, since it was never built by the paired-construction
     closure) through a real Batch_commit.t wired to the real Authorize.authorize. "Looks
     individually valid" on a casual read: positive amount, two distinct named accounts -- the
     one thing wrong with it is subtle, a merge_key that does NOT actually name this_account (a
     mismatch Legs.legs_of_request/legs_of_bytes can never produce by construction, so this shape
     can only arise from a direct, non-module-originated write -- precisely the "any sequence of
     operations," not just ones Legs itself would ever generate, that Review Focus requires).
     Asserts it is NOT silently accepted into the committed log just because its amount/accounts
     look fine at a glance -- authorize's own per-write merge_key check still gates it, end to
     end, exactly as it would for a Legs-originated write, even with no sibling present at all. *)
  let leg =
    Schema.
      {
        transfer_id = 42L;
        role = Debit;
        actor = "t";
        this_account = 7L;
        other_account = 9L;
        amount = 100L;
      }
  in
  let event_id = fake_event_id "direct-unpaired-leg" in
  let w =
    Riptide_batch_commit.Batch_commit.
      {
        actor = "t";
        causation = event_id;
        correlation = event_id;
        payload = Schema.transfer_leg_to_value leg;
        (* Mismatch: this leg claims to be about account 7, but its merge_key names account 99. *)
        merge_key = Some (Schema.account_merge_key 99L);
      }
  in
  let replica = create_solo () in
  let handle = Riptide_batch_commit.Batch_commit.create ~replica ~authorize:Authorize.authorize () in
  Riptide_batch_commit.Batch_commit.propose handle ~idempotency_key:"direct-unpaired-leg" [ w ];
  let committed = Riptide_batch_commit.Batch_commit.committed_envelopes replica in
  let leg_payloads =
    List.filter_map (fun (e : Riptide.Envelope.envelope) -> Schema.transfer_leg_of_value e.payload) committed
  in
  Alcotest.(check bool) "a direct, non-Legs-originated leg with a mismatched merge_key is denied, never committed"
    false
    (List.exists
       (fun (l : Schema.transfer_leg) ->
         l.transfer_id = 42L && l.this_account = 7L && l.other_account = 9L && l.amount = 100L)
       leg_payloads)

let tests =
  [
    QCheck_alcotest.to_alcotest test_no_malformed_leg_ever_reaches_the_log;
    QCheck_alcotest.to_alcotest test_legs_of_bytes_always_produces_nothing_or_a_balanced_pair;
    ( "a self-transfer request produces legs authorize denies",
      `Quick,
      test_a_self_transfer_request_produces_legs_authorize_denies );
    ("a non-positive-amount leg is denied", `Quick, test_a_non_positive_amount_leg_is_denied);
    ( "a direct unpaired leg write still passes authorize's own per-write checks alone",
      `Quick,
      test_a_direct_unpaired_leg_write_is_denied_not_just_a_module_originated_one );
  ]
