# Deploying Riptide to Kubernetes

Multi-node connectivity manifests: a `StatefulSet` (defaulting to 3 replicas — a starting point,
not a hard requirement; see the top-level [`README.md`'s "Running via Kubernetes"
section](../README.md#running-via-kubernetes) and Phase 3e), a headless `Service` for peer
discovery, a regular `Service` for client traffic, and a `Secret` template. If you change
`replicas:` in `statefulset.yaml`, also set `RIPTIDE_PLACEMENT_TARGET_SIZE` to match — they're
independently configurable, and the placement cluster only grows/shrinks to the target size you
give it, not automatically to however many pods happen to be running.

## Deploy

1. Copy the secret template and fill in real values:

   ```bash
   cp secret.example.yaml secret.yaml
   # RELEASE_COOKIE: openssl rand -base64 48
   # SECRET_KEY_BASE: mix phx.gen.secret (run from a Riptide checkout)
   ```

2. Apply everything:

   ```bash
   kubectl apply -f secret.yaml
   kubectl apply -f headless-service.yaml
   kubectl apply -f service.yaml
   kubectl apply -f statefulset.yaml
   ```

3. Wait for all 3 pods to become ready:

   ```bash
   kubectl rollout status statefulset/riptide
   ```

## Verify nodes are connected

```bash
kubectl exec -it riptide-0 -- bin/riptide remote
```

Then, in the remote IEx shell:

```elixir
Node.list()
# => [:"riptide@10.x.x.x", :"riptide@10.x.x.x"]  (the other two pods' IPs)
```

Repeat against `riptide-1`/`riptide-2` to confirm all three see the other two.

## Teardown

```bash
kubectl delete -f statefulset.yaml -f service.yaml -f headless-service.yaml -f secret.yaml
```

`secret.yaml` is git-ignored (see the repo's `.gitignore`) — never commit real
`RELEASE_COOKIE`/`SECRET_KEY_BASE` values.

## TLS

`ingress.yaml` and `cluster-issuer.yaml` (added in Phase 4d) add TLS termination at the ingress —
see the top-level [`README.md`'s "Running via Kubernetes" § TLS](../README.md#tls) for the full
setup walkthrough, rather than duplicating it here.
