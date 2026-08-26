# Phase 4d — TLS

## Context & motivation

Phase 4d is the fourth and final phase of sub-project 4 (Security & multi-tenancy), following
Phase 4a (multi-tenancy data model), Phase 4b (pluggable authentication), and Phase 4c
(authorization/ACP), all shipped 2026-08-26. Sub-project 4's original brainstorm already decided
TLS is terminated at the Kubernetes ingress/load balancer, not in-app, keeping it out of Riptide's
own Elixir codebase entirely. This phase turns that decision into concrete, documented example
manifests.

Riptide is distributed as a self-hosted OSS Docker image (`ghcr.io/openfaster-standard/riptide`)
with example Kubernetes manifests in `k8s/` that third-party operators copy and customize — not a
service this project deploys live anywhere itself. Phase 4d follows that same pattern: it adds
example manifests and documentation, not a live deployment.

## Scope

- A `networking.k8s.io/v1` Ingress routing a single hostname to the existing `riptide` ClusterIP
  Service, targeting **ingress-nginx**, with annotations tuned for Riptide's two long-lived-
  connection transports (SSE, WebSocket replication).
- A cert-manager `ClusterIssuer` for Let's Encrypt via **HTTP-01** (staging + prod variants).
- A one-line addition to `k8s/statefulset.yaml`'s `PHX_HOST` guidance: the public hostname
  (matching the Ingress), not the internal headless-service name.
- A new "Running via Kubernetes" section in `README.md` covering the full `k8s/` directory
  (previously undocumented since Phase 3b) plus the new Ingress/TLS pieces.

## Out of scope

- **Wildcard/DNS-01 certs** for the subdomain tenancy resolver (Phase 4a). Path-segment tenancy
  (the other Phase 4a resolver) only needs a single-hostname cert, which HTTP-01 handles with no
  DNS-provider credentials. Subdomain tenancy needs a wildcard cert, which ACME can only issue via
  DNS-01 (provider-specific API credentials) — deferred; docs will note the requirement and point
  to cert-manager's own DNS-01 provider docs rather than building/testing it here.
- **mTLS / client certificates.** No requirement surfaced; Phase 4c's ACP-based authorization
  already handles caller identity.
- **Cert rotation monitoring/alerting.** cert-manager renews automatically well before expiry; no
  additional Riptide-side monitoring is added.
- **A live, publicly-issued certificate as proof of correctness.** See Testing below — real
  ACME issuance needs a publicly resolvable domain and a publicly reachable ingress IP, which is a
  materially bigger, more public-facing ask than the in-cluster-only live tests earlier phases did.
  This phase is verified by manifest validation, not a live cert.
- **Non-ingress-nginx controllers** (Traefik, GKE Ingress, etc.). Documented as "should work with
  any cert-manager-compatible controller," but only tested/annotated for ingress-nginx.

## Architecture

No Elixir code changes. Confirmed by reading (not assuming) the existing config:

- `config/prod.exs` already sets `force_ssl: [rewrite_on: [:x_forwarded_proto], exclude:
  [paths: ["/health"], hosts: ["localhost", "127.0.0.1"]]]` — Plug.SSL trusts ingress-nginx's
  `X-Forwarded-Proto` header (set by default) to know the original request was HTTPS, and already
  exempts the StatefulSet's own `/health` probe.
- `config/runtime.exs` already sets `url: [host: host, port: 443, scheme: "https"]` (driven by the
  `PHX_HOST` env var) in the `:prod` block. This is what Phoenix's `Socket.check_origin` (used by
  the `/replication` WebSocket, `lib/riptide_web/endpoint.ex`) validates incoming `Origin` headers
  against — it compares against this configured URL, not against how the request physically
  arrived, so it is unaffected by TLS terminating upstream at the ingress.

The only operational change is that `PHX_HOST` must be set to the real public hostname (e.g.
`riptide.example.com`, matching the Ingress's `host`), not the StatefulSet's internal
`riptide-headless` value used for cluster-internal Erlang distribution.

## Manifests

### `k8s/ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: riptide
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["riptide.example.com"]
      secretName: riptide-tls
  rules:
    - host: riptide.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: riptide
                port:
                  number: 4000
```

- `cert-manager.io/cluster-issuer: letsencrypt-prod` — the standard cert-manager "ingress-shim"
  annotation. cert-manager watches Ingresses carrying this annotation and auto-issues/renews a
  certificate into the `tls[].secretName` Secret; no separate hand-written `Certificate` resource
  is needed.
- `nginx.ingress.kubernetes.io/proxy-buffering: "off"` — required for SSE. nginx buffers upstream
  responses by default, which would hold back `RiptideWeb.Realtime.SseController` events until a
  buffer fills instead of streaming them to the client as they're appended.
- `nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"` — nginx's default (60s) would kill idle
  SSE/WebSocket connections between events. Raised generously since a stream can go quiet
  indefinitely between appends and an idle connection is not an error condition.
- WebSocket `Upgrade`/`Connection` header pass-through (`RiptideWeb.Realtime.Socket` on
  `/replication`) needs no annotation — ingress-nginx forwards these automatically whenever the
  client sends the `Upgrade` header.
- `ingressClassName: nginx` pins to ingress-nginx explicitly rather than relying on a cluster's
  default `IngressClass`.

### `k8s/cluster-issuer.yaml`

Two `ClusterIssuer` resources, following cert-manager's own quickstart convention. Not named
`.example.yaml` — unlike `k8s/secret.example.yaml`, nothing in this file is a secret (an ACME
account email and an issuer name aren't sensitive), so it follows the same plain-naming convention
as `ingress.yaml`, `service.yaml`, and `statefulset.yaml`, all of which also have a `REPLACE_ME`-
style value an operator fills in without needing git-ignore treatment.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: REPLACE_ME@example.com
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: REPLACE_ME@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

Shipping both (not just prod) matters operationally: Let's Encrypt's production endpoint has strict
per-hostname rate limits, and a first-time operator debugging their Ingress/DNS setup can easily
exceed them by retrying. Staging has near-unlimited but untrusted-by-browsers certs, meant purely
for verifying the HTTP-01 challenge mechanics work before switching the Ingress annotation to
`letsencrypt-prod`.

### `k8s/statefulset.yaml`

One-line documentation change: the existing `PHX_HOST` env var's value/comment updated to note it
must be the real public hostname matching the Ingress once TLS is configured, not
`riptide-headless` (which remains correct for the cluster-internal Erlang-distribution use case
this field originally served in Phase 3b, when no public hostname yet existed).

## Documentation

Add a "Running via Kubernetes" section to `README.md`, positioned after the existing "Running via
Docker" section, covering:

1. Prerequisites: a Kubernetes cluster, `kubectl` access, ingress-nginx and cert-manager already
   installed (linking to their respective install docs — Riptide's manifests assume these exist,
   the same way the existing manifests assume a cluster already exists).
2. Applying the existing StatefulSet/Services (`k8s/statefulset.yaml`, `k8s/service.yaml`,
   `k8s/headless-service.yaml`, `k8s/secret.example.yaml`) — brief, since this predates Phase 4d
   and is being documented for the first time as a side effect of this phase, not redesigned.
3. Applying `k8s/cluster-issuer.yaml` (fill in a real ACME account email) and
   `k8s/ingress.yaml` (fill in the real hostname), pointing DNS at the ingress controller's
   external IP, and updating `PHX_HOST` to match.
4. A note on the subdomain-tenancy/wildcard-cert gap (see Out of scope above).

## Testing

Real end-to-end certificate issuance requires a publicly resolvable DNS name and a publicly
reachable ingress IP for Let's Encrypt's HTTP-01 challenge to solve against — a materially
different, more public-facing requirement than the in-cluster-only live tests earlier phases (3b,
3d-ii) performed against this org's own GKE cluster. This phase does not provision real public
DNS or a live certificate.

Verification instead consists of:

- `kubectl apply --dry-run=server -f k8s/ingress.yaml -f k8s/cluster-issuer.example.yaml` against
  a scratch namespace — validates the manifests against the live cluster's actual CRDs/admission
  webhooks (confirming cert-manager's `ClusterIssuer` CRD shape, the Ingress schema, etc.) without
  creating any resource that outlives the dry run. Run only with explicit confirmation before each
  invocation, since it is still a real call against a live cluster.
- Manual field-by-field review against `kubectl explain ingress.spec` /
  `kubectl explain clusterissuer.spec.acme` (or equivalent) to catch schema drift from
  cert-manager/ingress-nginx version differences.

No automated CI check is added for this phase — there is no Elixir code path to exercise, and the
manifests have no meaningful behavior outside a real cluster with real DNS.
