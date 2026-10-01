(** The ledger module's own policy for {!Riptide_batch_commit.Batch_commit.create}'s mandatory
    [~authorize] parameter -- the first real policy that universal checkpoint has ever carried
    (see docs/superpowers/specs/2026-10-01-layer2-ledger-module-design.md, Decision 1). Evaluated
    once per write, in isolation, with no visibility into any sibling write in the same batch --
    see that Decision for the full argument for why this function checks exactly what a SINGLE
    write can self-certify, and nothing about cross-write pairing (that guarantee comes from
    {!Legs} instead). *)

val authorize :
  Riptide_batch_commit.Batch_commit.write -> Riptide_batch_commit.Batch_commit.decision
(** [authorize w] branches on [w.merge_key]:
    - [Some "ledger.requests"]: always [Allow], unconditionally. A transfer request is not itself
      balance-affecting -- it only records what was asked for, business-rule evaluation (e.g.
      sufficient funds) happens later, inside the WASM module.
    - [Some mk] where [mk] starts with the literal prefix ["ledger.account."] (a transfer leg):
      decodes [w.payload] via {!Schema.transfer_leg_of_value}. [Deny] if that decode fails, or if
      the decoded leg's [amount <= 0L], or if its [this_account = other_account], or if [mk] does
      not equal {!Schema.account_merge_key} of its own [this_account] (a merge_key/account
      mismatch). [Allow] otherwise -- i.e. the leg is individually well-formed.
    - Anything else ([None], or a [merge_key] this module has no opinion on): [Allow] -- this
      module only ever has a verdict about its own two write shapes; every other write passes
      through untouched. *)
