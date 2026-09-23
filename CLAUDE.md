# Working conventions for this repo (v2)

This is a from-scratch rewrite. No backwards compatibility with v1 (the Solid/LDP/RDF/StreamLD
system that lives on `main` and every other pre-existing branch, untouched). The conventions
below are the process discipline the design phase concluded was the actual load-bearing
variable behind every historical success or failure of a system this ambitious — not the specific
architecture choices, which live in `.taskmaster/tasks/tasks.json`.

## No spec without running code

No rule for Layer 0 (or anything else in this repo) is ever allowed to exist as prose or a formal
spec alone. Working, tested code implementing the rule ships in the same change — no exceptions,
not even "we'll formalize this properly once we have more real usage to learn from."

**Why:** OSI's own historical record names this exact failure mode explicitly: ISO's standards
process ratified a complete paper design through committee consensus before any reference
implementation existed to test it against reality — CCITT rejected a *working, running* 1975
datagram proposal as "too risky and untested," preferring the paper-vetted alternative. TCP/IP
won specifically by refusing to do this: David Clark's IETF motto, "rough consensus and running
code," was coined as the direct rebuttal. Multics compounds the same disease with organizational
fracture on top (three institutions, three different payoffs, implementation split into silos so
severe that Bell Labs engineers wouldn't fix bugs in code that was "MIT's to own").

The sharpest warning is CORBA, not a confirming case: it started with real running vendor code
and a genuinely small initial mechanism (IDL + ORB) and *still* failed, because the mechanism
didn't stay small — object-adapter boilerplate ballooned from ~30 lines to 200+, and
security/versioning/naming/trading all got bolted on later as sprawling, committee-driven policy
specs. The failure isn't "was this general/ambitious from day one" — WebAssembly, LLVM's IR, HTTP,
and Kubernetes' CRD mechanism were all genuinely general from very early on and succeeded quickly.
The failure is specifically letting policy accumulate *ahead of* real, running, tested code.

**How to apply:** if you're about to write down a rule, a wire format, an invariant, an interface
— stop, and write the test and the implementation for it in the same sitting, not after. A design
doc that describes behavior no code yet exercises is a liability, not progress.

## Small, aligned governance for Layer 0

Changes to Layer 0 (the event envelope, consensus/replication protocol, content-addressed value
universe, atomic commit, lattice-law contract, and the Layer 0/Layer 2 boundary itself) are
decided by a small group, and every member of that group must have actually implemented against
the change they're approving — never a broad multi-stakeholder review where most participants
have no shipping stake in the outcome.

**Why:** this is what separated WebAssembly's ~2-year MVP-to-multi-engine-consensus timeline from
OSI's multi-decade committee gridlock. WASM's Community Group was four browser vendors, each of
whom had to ship working code in their own engine — spec and implementation never diverged for
years the way OSI's did, because nobody in the room *could* approve something they hadn't
built. IETF's own "at least two independent implementations" bar for standards-track advancement
is the same discipline stated as a formal rule.

**How to apply:** don't grow the Layer 0 decision-making group to "get more input" on something
architectural. Get more *implementations* instead — a second person building against a proposed
Layer 0 change is worth more than five people reviewing it who won't.

## Expect the first extension mechanism to need real revision

The Layer 0/Layer 2 boundary defined in Task 5 is explicitly provisional until Task 6 (one real,
demanding module, not several imagined ones) pressure-tests it and Task 7 revises whatever that
exposes. This is the expected, healthy shape of the work — not a sign anything went wrong.

**Why:** Kubernetes' own extension mechanism went through exactly this cycle before it worked —
ThirdPartyResources (the first attempt) had real, documented problems (no validation, poor
versioning, colliding schema storage) and was redesigned into CustomResourceDefinitions. Once
CRDs existed in their current form, they worked immediately across wildly different domains
(monitoring, service mesh, certificates, cloud infra) without needing a second redesign. The
lesson is sequencing, not perfection: get a real module built against the boundary fast, expect
to revise the boundary once, and don't mistake that revision for failure.

**How to apply:** when Task 6 is underway, keep a running, concrete list of every place the
Task 5 boundary made something harder than it should have been. That list *is* Task 7's scope —
nothing more, nothing speculative added on top of what real usage actually exposed.

## Task status is derived, never asserted

A parent task's `status` in `.taskmaster/tasks/tasks.json` is never set directly — it is always
the mechanical result of its subtasks' statuses (all done → done; all pending → pending; anything
else → in-progress), and every `"done"` status, parent or leaf, must be provable, not asserted: a
leaf task or subtask claiming `"done"` carries an `evidence.commits` array of real, git-resolvable
commit SHAs, proven to be ancestors of the branch making the claim, not a bare sentence saying so.

**Why:** this project already lived the exact failure this rule closes, not a hypothetical one.
`task-master-ai`'s own CLI correctly derives a parent's status from its children when a subtask is
updated *through the tool* — but does not enforce that derivation when a parent's status is set
directly, and its documentation claims the cascade is automatic when, in the version installed
here, it verifiably is not. Bulk JSON edits made directly against `tasks.json` this session,
bypassing the CLI, walked straight into that gap: Task 2 sat at `"done"` while all four of its
subtasks were still `"pending"`, and Task 3 sat at `"pending"` while four of its five subtasks
were `"done"` — drift a status field alone can't be told apart from a genuinely false completion
claim once it exists. This is the same class of failure this document's other rules already name
for code and governance — a task tracker's status column is not exempt just because it looks like
metadata rather than a system component.

**How to apply:** update a subtask's status directly (`task-master set-status --id=<id>.<n>
--status=<status>`); never hand-set a parent's. If the tool's derivation disagrees with what you
believe the parent's status should be, that's a signal the subtask breakdown needs revising, not
a reason to override the parent by hand. `evidence` is not something `task-master`'s CLI knows how
to write — add it via the same direct, careful JSON edit this project already uses for structural
changes to `tasks.json`, in the same change that moves a leaf to `"done"`, citing the real commit
SHA(s) (and PR URL, where one exists) that shipped the work. Run `scripts/validate-tasks` before
trusting any status read from this file locally — CI (`.github/workflows/validate-tasks.yml`) runs
it on every push/PR that touches `tasks.json`, but don't wait for CI to find out what running it
locally would have told you sooner.
