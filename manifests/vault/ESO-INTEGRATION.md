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
- **Policy `eso-read`** (`manifests/vault/policies/eso-read.hcl`): the
  permanent operational policy for real (non-test) secret access.
  Currently covers `kv/data/database/*` + `kv/metadata/database/*` only —
  widened one path at a time as real secrets migrate, same discipline as
  `eso-test-read` above.
- **Auth role `eso-role`**: bound to the same `external-secrets`
  ServiceAccount/namespace as `eso-test-role`, but mapped to the `eso-read`
  policy instead. Vault allows multiple roles to bind the same SA identity
  with different attached policies — `eso-test-role` and `eso-role` are
  both valid logins for the `external-secrets` SA, just requested by
  different `role=` names, so `eso-test-role` stays untouched and
  available for future throwaway smoke tests.
- **`ClusterSecretStore/vault-backend`** (`manifests/external-secrets/clustersecretstore.yaml`):
  points ESO at `http://vault.vault.svc.cluster.local:8200`, `kv` mount,
  `v2`, authenticating via **`eso-role`** (updated from `eso-test-role`
  once real policy existed) using ESO's own controller ServiceAccount
  (`serviceAccountRef`, not implicit pod identity). This is the permanent
  operational store now.

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

## Real secret migrations

### `pg-credentials` (database) — done, 2026-07-12

The shape followed, now the proven template for the remaining two:

1. Read the current live Secret's values, hashed (SHA-256) for later
   comparison — never printed to a terminal transcript or written to a
   repo file.
2. `vault kv put kv/database/pg-credentials password=... postgres-password=...`
   using the exact live values (a storage-backend migration, not a
   rotation).
3. New policy `eso-read` scoped to `kv/data/database/*` +
   `kv/metadata/database/*`, new auth role `eso-role` bound to the
   `external-secrets` SA — **not** reusing `eso-test-role`/`eso-test-read`,
   which stay reserved for throwaway smoke tests.
4. `ClusterSecretStore/vault-backend` updated to authenticate via
   `eso-role`.
5. `manifests/database/pg-credentials-externalsecret.yaml` committed:
   `target.creationPolicy: Merge` (not `Owner`) — patches the
   `password`/`postgres-password` keys into the **existing** manually-
   created Secret in place. No delete-then-recreate step, no gap where the
   Secret doesn't exist, no risk to the already-running Postgres pod.
   `target.deletionPolicy: Retain` — if this `ExternalSecret` is ever
   removed, the Secret and its data stay.
6. Verified: post-migration SHA-256 of both keys matched the
   pre-migration hashes exactly (no accidental rotation); `my-db-postgresql-0`'s
   restart count was unchanged (pod never touched); `db-connectivity-test`
   Job re-run and passed live against the real database, proving the
   ESO-managed Secret actually works end-to-end, not just that ESO
   *thinks* it synced.

### `git-creds` (argocd) — done, 2026-07-12

Same shape as `pg-credentials`, with two deltas:

- **Same policy file, one more stanza**, scoped to the exact secret path
  (`kv/data/argocd/git-creds`, not a `kv/data/argocd/*` glob) — same
  `eso-role` reused, only the policy content widened. Mirrors
  `role:jenkins-ci`'s precedent of starting scoped to an exact name and
  only widening to a glob once multiple secrets actually justify it (that
  moment will be `argocd-image-updater-secret`'s migration, next).
- **Functional verification couldn't reuse Image Updater's own reconcile
  loop** — it only exercises the git write-back codepath when there's an
  actual pending image change (`images_updated=0` at migration time), so
  watching its logs wouldn't have proven anything. Instead:
  `manifests/argocd/git-creds-test-job.yaml` (mirrors `db-test-job.yaml`)
  does a direct, read-only `curl -u <user>:<pass>` against the Gitea API
  (`GET /api/v1/repos/evanschepkwony1/gitops-galaxy`) and asserts
  `HTTP 200`. (First attempt used `git ls-remote` with credentials
  embedded directly in the URL — failed with "Bad hostname" because the
  username contains characters that need percent-encoding to safely
  appear in a URL; `curl -u` handles that correctly without needing to
  encode anything, so the Job uses that instead.)
- Verified: post-migration SHA-256 of both `username`/`password` matched
  pre-migration hashes exactly; `argocd-image-updater-controller`'s
  restart count unchanged; `git-creds-test-job.yaml` returned `HTTP 200`
  / `GIT_CREDS_TEST_PASSED` against the real Gitea API.

### `argocd-image-updater-secret` (argocd) — done, 2026-07-12

Same shape again, plus resolving the open question from the `git-creds`
entry above:

- **Confirmed the Secret's only key is `argocd.token`**, and that it's
  read directly from the Kubernetes API at runtime by the
  `argocd-image-updater` controller — not injected via env or a mounted
  volume (its `ClusterRole` grants `get` on `secrets`/`configmaps`
  cluster-wide, which is how it reads this well-known secret
  name/key). This is the ArgoCD API token for the `image-updater` local
  account (`role:image-updater` in `manifests/argocd/RBAC.md` §2 —
  `get`/`update` on `applications`, `*/*`).
- **Decided: keep exact-path stanzas, don't collapse to a
  `kv/data/argocd/*` glob**, even now that three real secrets exist
  under `argocd/`. `role:jenkins-ci`'s glob-widening precedent in
  `RBAC.md` was about multiple *environments* of the same application; these
  are three genuinely different secrets for different consumers. A
  namespace-wide glob would silently cover any future secret placed
  under `argocd/` without a deliberate, reviewable widening step — the
  exact thing this discipline exists to prevent. Three explicit lines
  costs nothing.
- **Functional verification**: `manifests/argocd/argocd-image-updater-token-test-job.yaml`
  does a live, read-only `curl` with `Authorization: Bearer
  <token>` against `https://argocd-server.argocd.svc.cluster.local/api/v1/applications`
  and asserts `HTTP 200` — proves the token actually authenticates and is
  authorized, not just that it's syntactically present.
- Verified: post-migration SHA-256 of `argocd.token` matched the
  pre-migration hash exactly; `argocd-image-updater-controller`'s restart
  count unchanged; the test Job returned `HTTP 200` /
  `ARGOCD_TOKEN_TEST_PASSED` against the real ArgoCD API.

## All three secrets migrated

`pg-credentials`, `git-creds`, and `argocd-image-updater-secret` are now
all ESO-managed via `ClusterSecretStore/vault-backend`. The only secret
management left outside this scope is the Jenkins credential store
(Gitea token, kubeconfig, ArgoCD token for the CI pipeline) — out of
scope for ESO entirely since it's K8s-only; would need a different
delivery mechanism (Vault Jenkins plugin/CSI) if ever migrated.
