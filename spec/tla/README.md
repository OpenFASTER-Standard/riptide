# TLA+ specifications

This directory holds the formal specification(s) for Riptide v2's Layer 0 consensus/replication
protocol, per `docs/superpowers/specs/2026-09-16-distributed-consensus-design.md`'s Decision 1
(VSR-derived, storage-fault-aware, crash-fault-tolerant).

Run any module: `scripts/tlc <ModuleName>` (from the repo root; looks for
`spec/tla/<ModuleName>.tla`/`.cfg`).

Toolchain: TLC 2.19 via `tla2tools.jar`, durably installed at `/work/toolchain/tla/tla2tools.jar`
(see cloud-admin-box's own `CLAUDE.md` for the install pattern — this box's filesystem outside
`/work` does not survive a pod restart).

## Scope

`VSR.tla` (added in later tasks of this plan) specifies VSR's **core safety protocol only**:
normal-case replication and view change. It deliberately excludes state-transfer,
storage-fault-aware recovery (nacks, repair), crash/restart modeling, and reconfiguration — see
this plan's own Global Constraints for why, and `docs/superpowers/plans/2026-09-17-vsr-core-safety-tla-spec.md`'s
final documentation task for what a follow-up plan needs to add.
