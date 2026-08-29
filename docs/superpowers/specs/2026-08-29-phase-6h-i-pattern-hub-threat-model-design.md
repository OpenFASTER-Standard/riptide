# Pattern Hub Threat Model — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6h-i**
(Foundation track). Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§6 — Catalog/DedupGate/Discovery/Pattern; §6.5 — Crosswalk; §7 — 6h-i's
own roadmap entry, and 6h-ii/6i's exit criteria this document gates; §10
— open questions). This document itself is the deliverable — 6h-i's exit
criterion is that it exists and is reviewed, not that any code ships.

## 1. Scope

Per the parent spec's §7 entry: the auth/rate-limit threat model for the
Pattern Hub's network-public surface, gating 6h-ii's implementation.

**Exit criterion:** a written auth/rate-limit threat model for the Hub's
network surface exists and is reviewed, before 6h-ii starts.

**Depends on:** nothing.

**Governance model this document is grounded against** (parent spec §6,
corrected in the eleventh revision — see that spec's own §11): **Tenant
is the sovereign unit.** There is no central, Riptide-operated curator
role. Any Tenant may publish/share a CatalogEntry, reviewed and admitted
through that same Tenant's own already-shipped DedupGate authority
(6e-iii) — never a separate third-party reviewer. Sharing is designed to
work identically whether the receiving Tenant is on the same Riptide
deployment or a different, independently-operated one (federation, a
stated design goal with cross-instance trust verification explicitly
deferred). This correction was found *during* this document's own
brainstorming — an earlier draft spent significant effort designing a
"curator authorization" mechanism for a role the parent spec had never
concretely defined; every design that emerged either invented
infrastructure that didn't fit the intended model or quietly
reintroduced the same undefined-role problem in a new shape. The parent
spec was corrected first (see its own §11, eleventh revision) before
finishing this document.

## 2. Key findings

**The central "who is a curator" authorization problem doesn't exist
under the corrected model — verified, not assumed.** Every write action
on this surface is always performed *as* some real, already-existing
Tenant:

- **Propose-to-Hub** — a Tenant publishing its own CatalogEntry. Gated by
  that Tenant's own ordinary write authorization
  (`Riptide.Authz.evaluate/4`, `tenant_id` = the publishing Tenant's own
  real id — never a fake or reserved one). No new authorization
  primitive.
- **Approve/decline-review** — the mandatory human review 6e-iii already
  requires before `Admit`/`Merge` becomes live, performed by that same
  Tenant's own team, using the same ordinary tenant-scoped write
  authorization. No new authorization primitive.
- **Install** — the *installing* Tenant pulling a Hub-scope CatalogEntry
  into its own Catalog, gated by the installing Tenant's own ordinary
  write authorization on its own resources. No new authorization
  primitive.
- **Crosswalk-propose** — structurally identical to propose-to-Hub, a
  different content type through the same mechanism.

Confirmed directly against `Riptide.Authz.evaluate/4`
(`lib/riptide/authz.ex:14-15`): its `tenant_id`-required signature is not
a structural mismatch here (as an earlier draft of this analysis
concluded, before the governance correction) — every caller in this
surface already has a real tenant_id to supply, its own. `evaluate/4`
needs zero changes.

**Consequence: the sharpest threat identified in an earlier draft (a
single shared pending-review queue one attacker could flood to lock out
every other legitimate proposer) does not apply.** Each Tenant reviews
only its own queue — there is no shared bottleneck for one Tenant's flood
to starve another Tenant's attention. Ordinary per-tenant quotas (the
same shape as the already-shipped `@max_streams_per_tenant`,
`lib/riptide/stream/placement.ex`) are a sufficient, natural fit; no new
global soft-cap-with-alerting mechanism is needed.

**Consequence: the most important residual risk is data leakage via
incomplete generalization (T4 below), not privilege escalation.** With
no central reviewer acting as a safety net, a Tenant's own review before
publishing is the *only* check against a tenant-specific literal
(hostname, account ID, API key, PII) shipping into a publicly-installable
Pattern — anti-unification only turns a position into a variable where
source Traces actually *disagreed* (6e-i), so a literal that happens to
be constant across every Trace a Tenant has seen so far looks
structurally identical to a genuinely-invariant part of the Pattern.

**What remains genuinely new:** only the Hub's *read* path (Discovery,
Catalog fetch) is inherently cross-tenant by nature — nobody "owns" a
search across every Tenant's published content the way a Tenant owns its
own write actions. This is where real new design work is needed (§6).

## 3. Assets

- **Tenant confidentiality** — a Tenant's own unpublished data must never
  leak into a published Pattern (T4).
- **Hub read availability** — the shared Discovery/Catalog-fetch surface
  must survive being hit by many callers at once (T1).
- **Per-Tenant publish/review integrity** — a Tenant's own DedupGate
  review must not be bypassable by any subject other than that Tenant's
  own authorized members (T5, reduces to Sub-project 4's already-shipped
  tenant-isolation guarantee).
- **Install-target integrity** — installing a Hub Pattern must not let
  its origin Tenant write anything into the installing Tenant's Catalog
  beyond what the installing Tenant's own DedupGate reviews and approves
  (T5).
- **Crosswalk correctness** — a false SSSOM assertion must not silently
  misbind fields during Install (T6).

## 4. Attacker model & trust boundaries

- **Anonymous network caller** — untrusted, may attempt to read (Hub
  Discovery) or flood any network-reachable endpoint.
- **Authenticated Tenant subject, acting within their own Tenant** —
  trusted for their own Tenant's actions (publish/review/install/
  Crosswalk-propose) to the exact extent Sub-project 4's existing
  ACP-style authorization already trusts any tenant-scoped write today.
  Not trusted, and never granted any capability, over any *other*
  Tenant's own review/publish decisions.
- **A compromised or malicious Tenant credential** — can publish
  low-quality or malicious content *as that Tenant*, discoverable and
  installable by others (T5) — the same blast radius as a compromised
  credential has always had under Sub-project 4's model, now extended to
  content that becomes broadly visible rather than staying tenant-local.
- **A future cross-instance caller** (federation) — explicitly out of
  scope for 6h-ii's own first implementation (parent spec §6); this
  document does not threat-model cross-instance trust establishment,
  only flags that the protocol shape 6h-ii builds should not preclude it
  later (§10).

## 5. Attack surface

Cross-referenced to parent spec §6/§6.5:

| Operation | Direction | Authorization |
|---|---|---|
| Discovery / Catalog fetch (Hub scope) | Read | Optional auth (§6) |
| Propose-to-Hub | Write | Publishing Tenant's own `Authz.evaluate/4` |
| Approve/decline-review | Write | Same Tenant's own `Authz.evaluate/4` |
| Install (Hub → Tenant) | Write | Installing Tenant's own `Authz.evaluate/4` |
| Crosswalk-propose | Write | Proposing Tenant's own `Authz.evaluate/4` |

## 6. Design decision: Hub read access

Hub read access (Discovery, Catalog fetch) uses **optional
authentication, reusing `RiptideWeb.Plugs.Authenticate` completely
unmodified** — no token required to proceed (matching every other route
today); authenticated Tenant subjects get subject-keyed rate limiting
(T1) and accountability; anonymous or future cross-instance callers can
still read, falling back to weaker IP-based limiting only — an
explicitly accepted residual risk (T7), not silently ignored. Zero new
auth-plug logic.

Two other postures were considered and ruled out: requiring
authentication for all Hub access (simplest, most uniform, but directly
conflicts with the parent spec's own "reachable by any Tenant, including
future external ones" framing, §6); and genuinely anonymous access with
only IP-based limiting (weakest defense — NAT/botnet-fragile — and zero
accountability for the common case where a caller is in fact an
authenticated Tenant). Optional auth strictly dominates both: it
preserves the same anonymous reachability the fully-anonymous option
provides, while adding accountability for every caller who already has
an identity, at zero implementation cost beyond reusing what's shipped.

## 7. Threats & mitigations

**T1 — Discovery flood (read-path DoS).** `Discovery.find/2`'s cost
scales with catalog size per call (6g-i); an unauthenticated or
cheap-to-repeat read can drive unbounded search load.
*Mitigation:* a new Hammer `:fix_window_per_key` limiter (mirroring
`Riptide.NewStreamRateLimit`'s exact shape,
`lib/riptide/new_stream_rate_limit.ex`) for Hub reads, keyed by
authenticated subject when present, else by caller IP.

**T2 — Per-tenant propose volume.** A single Tenant proposing an
excessive volume of Hub-scope candidates could grow that Tenant's own
pending-review queue unmanageably (its own team's problem to self-manage,
not a cross-tenant DoS, per §2's finding).
*Mitigation:* an ordinary per-tenant quota, the same shape as the
already-shipped `@max_streams_per_tenant`
(`lib/riptide/stream/placement.ex`) — a Tenant-owned limit, not a
shared, cross-tenant-contentious one.

**T3 — [Retired].** Privilege escalation on review resolution — the
threat an earlier draft treated as highest-severity, predicated on a
central curator role that does not exist under the corrected governance
model (§2). Retained as a numbered entry, marked retired, so a future
reader of this document's history can see it was considered and why it
no longer applies, rather than silently vanishing.

**T4 — Tenant-data leakage via incomplete generalization (the most
important residual risk in this document).** Anti-unification only
turns a position into a variable where source Traces actually
*disagreed* (6e-i) — a literal constant across every Trace a Tenant has
seen so far looks structurally identical to a genuinely-invariant part
of the Pattern. A tenant-specific hostname, account ID, API key, or PII
value can ship into a publicly-installable Pattern verbatim, with no
central reviewer as a safety net.
*Mitigation:* the Tenant's own mandatory human review before
`Admit`/`Merge` (6e-iii, already shipped) is the *sole* line of defense
— this document does not invent a new automated scanning mechanism, but
explicitly requires 6h-ii's own UI/workflow to make the reviewing
Tenant's own responsibility here unambiguous (a review-checklist
requirement, §8) rather than silently assuming generalization alone is
safe.

**T5 — Compromised Tenant credential, amplified via Install.** A
compromised or malicious Tenant can publish content that other Tenants
subsequently install — the compromise's blast radius extends beyond the
one Tenant, same in kind as any compromised tenant credential already
poses under Sub-project 4's model, now amplified by installability.
*Mitigation:* no new mechanism — this is exactly what Sub-project 4's
existing credential/authorization hygiene already defends, and what T4's
review requirement (above) bounds on the content side. Structured audit
logging of who published/approved/installed what (Phase 5b precedent)
aids incident response if it happens.

**T6 — Crosswalk poisoning.** A false SSSOM assertion (`exact_match`
where fields aren't actually equivalent) silently misbinds fields during
Install — an integrity risk.
*Mitigation:* no bespoke mechanism — Crosswalk-propose goes through the
identical per-Tenant DedupGate authority as any other Hub-scope
publication (§2), so it reduces entirely to T4/T5's own mitigations.

**T7 — Reconnaissance via Hub read access.** Depending on §6's read-auth
answer (below), an attacker may enumerate every published Pattern/
Crosswalk to fingerprint what integrations exist. Lower severity — this
content is designed to be publicly discoverable — but named as an
accepted residual risk, not silently assumed away.

**T8 — Auth-mechanism drift on the new deployment.** 6h-ii is a
network-publicly-reachable deployment (parent spec §7) — a real risk is
it getting its own, subtly different auth wiring instead of reusing
`RiptideWeb.Plugs.Authenticate`/`Riptide.Auth.Verifier.OIDC`/Phase 4d's
TLS termination unmodified. A second bespoke implementation is exactly
where security bugs get silently reintroduced.
*Mitigation:* explicit requirement in this document: 6h-ii must wire
authentication identically to every existing route, zero new auth code
paths.

**T9 — [Retired].** `Authz.evaluate/4`'s `tenant_id`-required signature
being a structural mismatch — an earlier draft's concern, predicated on
the same now-corrected central-curator assumption as T3. Verified
directly (§2): every caller in this surface already has a real tenant_id
to supply. No mismatch exists.

**T10 — Rate-limit evasion via cheap tenant/identity minting.**
`tenant_id` is free to mint (Phase 4a) — a limiter keyed by `tenant_id`
rather than authenticated subject is trivially evaded by spreading
requests across freshly-minted tenant IDs.
*Mitigation:* every Hub-scope limiter (T1, T2) keys on authenticated
subject or IP, never on `tenant_id` — mirroring
`NewStreamRateLimit`'s own `"new_stream:#{subject}"` choice.

**T11 — Expensive/pathological propose payloads.** A propose-to-Hub
candidate runs through `AntiUnifier.generalize/2`/
`GeneralizationFidelity.check/3` before DedupGate even decides — an
oversized or pathological (e.g. deeply recursive) candidate is expensive
per-call, independent of call *rate*.
*Mitigation:* an input-size/shape cap on propose payloads, enforced
before those calls — same risk class as the already-shipped JWKS-timeout
and policy-list dedup/cap precedent (PROGRESS.md §4's post-4d
hardening).

## 8. Testing & verification expectations for 6h-ii

Since this document's own exit criterion is "written and reviewed," not
"implemented," this section states what 6h-ii's own future test plan
must cover to prove each mitigation actually holds:

- A flood test proving the Discovery/read limiter (T1) throttles.
- A test proving a per-tenant propose quota (T2) is enforced and does
  not affect any *other* Tenant's own quota.
- A test proving propose/approve-review/install/Crosswalk-propose all
  correctly deny a subject with no write authorization on the relevant
  Tenant — exercising the *existing*, unmodified `Authz.evaluate/4` path
  (§2), not a new mechanism.
- A test proving 6h-ii's own auth wiring is byte-for-byte the same
  `Authenticate`/`Verifier.OIDC` path every other route already uses
  (T8) — e.g. asserting on the actual plug pipeline, not just behavior.
- A test proving an oversized/pathological propose payload (T11) is
  rejected before reaching `AntiUnifier`/`GeneralizationFidelity`.
- A documented review-checklist requirement (not a test) that a Tenant's
  own reviewer is explicitly prompted to screen for tenant-identifying
  literals before approving a Hub-scope `Admit`/`Merge` (T4).

## 9. Exit criterion (from parent spec §7, restated)

A written auth/rate-limit threat model for the Hub's network surface
exists (this document) and is reviewed (pending explicit sign-off),
before 6h-ii starts. Satisfied once this document is approved.

## 10. Explicitly deferred / residual risks

- **Cross-instance federation's own trust/identity verification**
  (parent spec §6) — 6h-ii builds the network-reachable protocol shape
  now (HTTP, not same-BEAM-node-only), but establishing trust between
  two independently-operated Riptide deployments is real, separate
  design work, deferred until a concrete cross-instance use case exists.
  This document's own mitigations (T1, T2, T10) are keyed by
  subject/IP, which already extends sensibly to a future cross-instance
  caller without redesign — worth noting, not a claim that federation
  is otherwise ready.
- **T7 (reconnaissance via Hub read)** — accepted residual risk, a direct
  consequence of §6's own optional-auth design decision permitting
  anonymous reads at all.
- **Automated PII/secret-literal scanning as defense-in-depth for T4** —
  worth flagging as a future strengthening, not required to ship this
  document; the mandatory human review remains the primary, sufficient
  control for now.
- **T3, T9 (retired)** — kept as numbered, explicitly-retired entries
  (§7) rather than removed, so this document's own history stays
  legible to a future reader who might otherwise wonder why an earlier
  linked discussion (or the parent spec's own eleventh-revision
  changelog entry) referenced a "curator" concept this document no
  longer uses.
