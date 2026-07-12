# Vault <-> External Secrets Operator wiring

This documents the non-declarative Vault configuration behind
`manifests/external-secrets/clustersecretstore.yaml` — the pieces applied
via the `vault` CLI rather than `kubectl apply`, plus the rationale, same
role `manifests/argocd/RBAC.md` plays for ArgoCD's own non-declarative
config.

## What's wired up

- **KV v2 engine** mounted at `kv/`. Path layout: `kv/<namespace>/<secret-name>`,
  mirroring the existing 1:1 naming between K8s Secret names and their
  logical identity (e.g. a future `pg-credentials` migration would live at
  `kv/database/pg-credentials`). `kv/test/*` is reserved for throwaway
  proof-of-concept data and is never a real namespace.
- **Kubernetes auth method** enabled at `auth/kubernetes/`, configured
  against this cluster's own API (Vault auto-detects its own pod's
  CA/token since it's running in-cluster — no external kubeconfig needed).
  Requires the `vault` ServiceAccount to hold `system:auth-delegator`
  (`manifests/vault/vault-tokenreview-clusterrolebinding.yaml`) so Vault
  can call the TokenReview API to validate tokens ESO presents.
- **Policy `eso-test-read`** (`manifests/vault/policies/eso-test-read.hcl`):
  read-only on `kv/data/test/*` and `kv/metadata/test/*`. Deliberately
  narrow — not `kv/*` — following this repo's own `role:jenkins-ci` (tight
  glob-scoping) vs `role:image-updater` (unscoped `*/*`, flagged as a
  mistake) precedent in `manifests/argocd/RBAC.md`.
- **Auth role `eso-test-role`**: bound to the `external-secrets`
  ServiceAccount in the `external-secrets` namespace only, mapped to the
  `eso-test-read` policy, `ttl=1h`.
- **`ClusterSecretStore/vault-backend`** (`manifests/external-secrets/clustersecretstore.yaml`):
  points ESO at `http://vault.vault.svc.cluster.local:8200`, `kv` mount,
  `v2`, authenticating via `eso-test-role` using ESO's own controller
  ServiceAccount (`serviceAccountRef`, not implicit pod identity).

## Commands run (imperative — no install-script convention in this repo)

```bash
kubectl apply -f manifests/vault/vault-tokenreview-clusterrolebinding.yaml

# Inside vault-0, authenticated with the root token (never committed):
vault secrets enable -path=kv -version=2 kv
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}"

vault policy write eso-test-read /tmp/eso-test-read.hcl   # copied in via kubectl cp

vault write auth/kubernetes/role/eso-test-role \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-test-read \
  ttl=1h
```

## Round trip proven live (2026-07-12), then torn down

```bash
vault kv put kv/test/hello foo=bar
# applied a throwaway ExternalSecret in `external-secrets` targeting
# test/hello -> materialized Secret's `foo` key decoded to `bar`
# cleaned up: deleted the ExternalSecret, the materialized Secret, and
# `vault kv metadata delete kv/test/hello`
```

See `manifests/external-secrets/README.md` for the exact reproducible
steps if you want to re-run this smoke test.

## Widening this for a real secret migration

When migrating a real secret (e.g. `pg-credentials`), the general shape:

1. `vault kv put kv/database/pg-credentials password=... postgres-password=...`
2. A new policy scoped to `kv/data/database/*` (or extend `eso-test-read`
   if reusing the same role makes sense for that consumer).
3. A new Vault auth role bound to whichever ServiceAccount actually needs
   read access (do **not** just reuse `eso-test-role` broadly — keep the
   one-role-per-consumer discipline `RBAC.md` establishes for ArgoCD).
4. A real `ExternalSecret` in the `database` namespace, committed to the
   repo (not transient like the proof-of-concept above) targeting
   `vault-backend`, writing a `Secret` named `pg-credentials` so nothing
   else in `manifests/database/values.yaml` needs to change
   (`existingSecret: pg-credentials` keeps working — ESO becomes the
   thing that keeps that Secret populated instead of a human).
5. Remove the original manually-created `pg-credentials` Secret only after
   confirming the ESO-managed one reconciles successfully.
