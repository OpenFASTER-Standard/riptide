# Mandatory Kv_store_intf.S ownership: closing subtask 4.8's residual gap

Design spec for task-master subtask 4.8's remaining half — requiring an owner tag at
`Materializer.create`'s type level, not just by convention — broadened, per user direction, to
also close the residual gap subtask 4.8's own `Redaction_store.create` fix left open: a directory
that never gets a `~owner` at all (on either side of a potential collision) is invisible to every
existing check, since `File_kv_store`'s own owner-marker guard is a documented no-op for `None`.
This document is the argument; the implementation plan and running code that follow it are the
authority, per `CLAUDE.md`'s "no spec without running code" rule.

## Context

Subtask 4.8 closed `Redaction_store.create`'s half already (commit history: `File_kv_store` gained
`owner : t -> string option`; `Redaction_store.create` asserts `File_kv_store.owner kv = Some
Redaction_store.owner_tag` as its first statement, before the record is constructed). Its
`Materializer.create` half was deliberately deferred: `Materializer.Make` is a *functor* over
`KV : Kv_store_intf.S`, so unlike `Redaction_store.create` (which takes a concrete
`File_kv_store.t` and can call `File_kv_store.owner` directly), `Materializer.create` only ever
sees `KV.t` abstractly — it structurally cannot ask an arbitrary `Kv_store_intf.S` implementer
whether it has an owner, because the interface itself carries no such concept.

Separately, `Redaction_store.mli`'s own doc comment on its already-shipped fix names a residual
gap it explicitly does not close: a second consumer that builds its own `File_kv_store.create`
over the same directory *without passing `~owner` at all* is undetectable, because
`check_or_write_owner_marker` is a documented no-op when `owner = None`. This is the same failure
class subtask 4.8 already closed once for `Materializer.create`/`Redaction_store.create`
specifically — "a safe path exists, but nothing stops you skipping it" — just one layer further
down, at `File_kv_store.create` itself.

Both gaps share one root cause (`?owner` is optional, so "no owner" is a legitimate, constructible
state everywhere in the stack) and one fix: make ownership mandatory, all the way down, so the
unprotected state stops being expressible rather than merely being easy to skip.

## Decision 1: `Kv_store_intf.S` gains a required `owner` accessor

```ocaml
val owner : t -> string
(** The tag this store was constructed with. Every implementer must have one; a backend with no
    real ownership/collision-risk concept (e.g. a future in-memory test double with no shared-
    directory hazard) can return a fixed placeholder — this is exactly as cheap and exactly as
    honest as the existing convention throughout this codebase that an accessor with nothing real
    to report returns a harmless constant rather than forcing every caller to handle absence. *)
```

`File_kv_store` is the interface's only real implementer today (confirmed by `grep` across
`lib/`/`test/`), so this is a zero-cost addition in practice; the cost is borne by any future
implementer, which is judged worth paying to keep the interface's own guarantee — "every store
that exists has a declared owner" — total rather than partial.

## Decision 2: `File_kv_store.create`'s `?owner` becomes mandatory

`?owner:string` (optional, `None` default) becomes `owner:string` (required, no default).
`check_or_write_owner_marker` loses its `None` branch entirely — every call now has a real tag to
check or write, so the function's own body simplifies along with its contract.
`owner : t -> string option` becomes `owner : t -> string` (Decision 1's shape) — the field itself
simplifies the same way the constructor does, since there is no longer a `None` case for a reader
to handle. This is the fix for the residual gap: a directory can no longer be pointed at by a
`File_kv_store.create` that supplies no tag at all, on either side of a potential collision.

## Decision 3: `Materializer.create` gains a required `~owner:string` and checks it

```ocaml
val create : kv:KV.t -> owner:string -> decode:(string -> L.t) -> encode:(L.t -> string) -> t
(** @raise Invalid_argument if [KV.owner kv <> owner] -- before [t] is constructed, mirroring
    {!Riptide_crypto.Redaction_store.create}'s own check exactly. *)
```

Unlike `Redaction_store.owner_tag` (one fixed, project-wide-unique constant — there is exactly one
redaction keystore's worth of directories in this system), `Materializer` instances are built by
different callers for different `merge_key` namespaces, so there is no single tag to export as a
constant; the caller supplies whatever tag it built its own `kv` with, and `create` simply checks
the two agree.

## Decision 4: `Redaction_store.create`'s existing check simplifies to match

`actual <> Some owner_tag` (with an `Option.value ~default:"(none)"` in the error message) becomes
`actual <> owner_tag` (no `Option`, no "(none)" case to report) — Decision 2's simplification
propagates through its one real consumer.

## Migration and retirement

No production code is affected — `Materializer.Make(...).create` has zero non-test callers today
(no `bin/` entrypoint exists yet). All effect is in `test/`:

- **~15 bare `File_kv_store.create` call sites** (mostly `test_file_kv_store.ml`'s basic CRUD
  tests, unrelated to the collision hazard) need a one-line `~owner:"..."` addition to keep
  compiling.
- **Three tests are retired, not repurposed**, because the state they exist to pin becomes
  unconstructible rather than merely harder to reach:
  - `test_file_kv_store.ml`: `"no owner supplied is unaffected (backward compatibility)"`.
  - `test_redaction.ml`: `test_create_rejects_an_untagged_kv`.
  - `test_lattice_materialize_crypto_scenarios.ml`:
    `test_omitting_owner_on_the_materializer_side_alone_still_destroys_a_wrapped_dek`.
  Each retirement's commit message states plainly that the scenario the test proved is now a
  compile error, not merely that the test was deleted — `dune build`'s own failure on a
  reconstructed version of the old call is the running-code proof `CLAUDE.md` requires for a
  compile-time guarantee, since OCaml has no runtime way to assert "this does not typecheck."
- `Redaction_store.mli`'s own doc comment (the paragraph naming the residual gap this design
  closes) gets rewritten to say so, rather than continuing to name an open gap that no longer
  exists.

## New tests

`test_materializer_create_rejects_a_kv_tagged_for_a_different_owner` — mirrors
`test_redaction.ml`'s `test_create_rejects_a_kv_tagged_for_a_different_owner` exactly: build `kv`
with `~owner:"some-other-owner"`, call `Materializer.Make(L)(File_kv_store).create ~kv
~owner:"materializer" ...`, assert `Invalid_argument` with the exact message. No separate
`Kv_store_intf.S`-level test is needed — `File_kv_store` is the sole implementer, and its own
existing owner tests already cover the accessor's contract; this new test covers the consumer
side, the only side this design adds behavior to.

## Non-goals

- No new `Kv_store_intf.S` implementer is being added or anticipated.
- No change to the marker-file mechanism, the mismatch error shape, or "first `create` of a
  directory wins" semantics — this design only removes the `None`/opt-out branch from all of it.
- `Batch_commit` is unaffected — it references `Kv_store_intf.S` only in prose, never
  functorizes over it.
