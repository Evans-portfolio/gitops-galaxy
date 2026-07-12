# Jenkins <-> Vault wiring (Jenkins credential store migration)

Jenkins runs as a Docker container on the host, not in-cluster, so ESO
(Kubernetes-only) can't serve it directly — this documents the separate
mechanism used: the official HashiCorp Vault Jenkins plugin, backing the
same three Jenkins credential IDs the `Jenkinsfile` already references
(`gitea-jenkins-token`, `argocd-jenkins-token`, `jenkins-kubeconfig`), so
**no Jenkinsfile changes were needed**.

## What's wired up

- **Vault NodePort** (`manifests/vault/vault-nodeport.yaml`, port `30820`):
  required because Jenkins cannot reach Vault's ClusterIP at all — it's
  on the Docker `minikube` network, which only routes to the minikube
  node's exposed NodePorts (confirmed empirically; this is also *why*
  ArgoCD's NodePort exists). TLS is still disabled on Vault's listener,
  so this NodePort serves plain HTTP — the Jenkins↔Vault hop stays local
  (Docker bridge → minikube node), same risk posture already accepted
  for the rest of this Vault install.
- **AppRole auth method** (`vault auth enable approle`) — Vault's
  standard pattern for non-Kubernetes external systems. Role `jenkins`,
  policy `jenkins-read` (`manifests/vault/policies/jenkins-read.hcl`):
  read-only on `kv/data/jenkins/*` as a **glob**, deliberately different
  from `eso-read.hcl`'s exact-path discipline for `argocd/*` — `jenkins/`
  is a prefix dedicated to this one consumer (Jenkins' own AppRole), so
  a glob here doesn't carry the same "silently covers future unrelated
  secrets" risk that motivated exact paths under the shared `argocd/`
  prefix.
- **AppRole RoleID/SecretID bootstrap**: generated via `vault read
  auth/approle/role/jenkins/role-id` and `vault write -f
  auth/approle/role/jenkins/secret-id`, written as files on the
  `jenkins_home` volume (`/var/jenkins_home/vault-approle/{role-id,secret-id}`,
  `chmod 600`) rather than committed anywhere. These files are the
  durable, git-independent source of truth for Jenkins' one bootstrap
  identity.
- **HashiCorp Vault plugin** (`hashicorp-vault-plugin`) installed via
  `jenkins-plugin-cli`. Note: this Jenkins image uses
  `-Dhudson.lifecycle=hudson.lifecycle.ExitLifecycle`, meaning
  `/safeRestart` cleanly exits the JVM but does **not** bring the
  container back — the container's restart policy is `no`, so a plugin
  install always needs a manual `docker start jenkins` after the restart
  request, not just a wait.
- **One Jenkins Credential holds the AppRole identity** (`VaultAppRoleCredential`,
  ID `vault-approle-jenkins`), constructed via the Script Console by
  reading the RoleID/SecretID files above. This is the one unavoidable
  root-of-trust secret — some single credential always has to unlock
  everything else. Net effect: **three separate application secrets
  reduced to one minimal bootstrap credential**, which is the realistic
  target here, not literally zero secrets in Jenkins.
- **Three Vault-backed credentials, same IDs as before**:
  - `gitea-jenkins-token` → `VaultUsernamePasswordCredentialImpl`,
    path `kv/jenkins/gitea-token`, keys `username`/`password`.
  - `argocd-jenkins-token` → `VaultStringCredentialImpl`,
    path `kv/jenkins/argocd-token`, key `token`.
  - `jenkins-kubeconfig` → `VaultFileCredentialImpl`,
    path `kv/jenkins/kubeconfig`, key `content`.

  **Path format note**: each credential's `path` must include the KV
  mount name (`kv/jenkins/...`), not just the path within the mount
  (`jenkins/...`). The global `VaultConfiguration.prefixPath` setting
  does **not** get automatically combined with each credential's own
  `path` the way it might look like it should — confirmed empirically
  via reflection + trial against a disposable test path before touching
  the real credentials (see "How this was verified" below). Similarly,
  each credential needs its own `engineVersion` set (inherited setter,
  separate from the global config's).

## Commands run (imperative, matching this repo's convention)

```bash
kubectl apply -f manifests/vault/vault-nodeport.yaml

# Inside vault-0, authenticated with the root token:
vault auth enable approle
vault policy write jenkins-read /tmp/jenkins-read.hcl
vault write auth/approle/role/jenkins \
  token_policies=jenkins-read token_ttl=1h token_max_ttl=4h

vault read -field=role_id auth/approle/role/jenkins/role-id
vault write -f -field=secret_id auth/approle/role/jenkins/secret-id
# -> written to jenkins_home/vault-approle/{role-id,secret-id}, chmod 600

docker exec jenkins jenkins-plugin-cli --plugins hashicorp-vault-plugin
# safeRestart via API, then `docker start jenkins` (ExitLifecycle, see above)
```

Reading the original credential values and writing them to Vault used the
Script Console (`/scriptText`), piping resolved values directly into
shell variables and then into `vault kv put` — never landing in an
intermediate file. (One early attempt *did* write raw values to a scratch
file before being caught and corrected — worth noting since it's the
kind of mistake this pattern is designed to avoid.)

## How this was verified

1. **Byte-for-byte**: SHA-256 of all four values (gitea username,
   password, argocd token, kubeconfig content) hashed before touching
   Jenkins' credential store and after — identical.
2. **Staged cutover, not direct**: three temporary credentials were
   created first under `-vaulttest`-suffixed IDs, resolved successfully
   (this is where the `kv/jenkins/...` path format issue above was
   caught and fixed), *then* the real IDs were swapped atomically
   (delete native, create Vault-backed) in one Script Console call, and
   only then were the test-ID credentials removed.
3. **Real pipeline run**, not just credential resolution: triggered
   build #9 via the Jenkins API, which ran Checkout (git fetch via
   `gitea-jenkins-token`) → Commit & push (real git push via the same
   credential) → Deploy to Dev (`kubectl apply` via `jenkins-kubeconfig`,
   `argocd app sync`/`wait` via `argocd-jenkins-token`) → Deploy to
   Staging (same) — both `sorcery-app-dev`/`sorcery-app-staging` reached
   `Healthy`. Paused at the "Promote to production?" gate and was
   **aborted** (not approved) via the input-abort API. Result: `ABORTED`,
   not `FAILURE` — confirms the `post{failure}` rollback logic correctly
   did not fire, matching the documented behavior from the original
   multi-env promotion test in `NOTES.md`.
4. `credentials.xml` confirmed to hold `VaultAppRoleCredential` +
   `VaultUsernamePasswordCredentialImpl`/`VaultStringCredentialImpl`/`VaultFileCredentialImpl`
   for the four relevant IDs — no more native plaintext-backed entries
   for the three migrated secrets.

## Out of scope / known follow-ups

- The hardcoded admin-password bootstrap script
  (`init.groovy.d/basic-security.groovy`) was a separate, unrelated issue
  discovered and fixed during this work (now idempotent, sources a real
  password from `JENKINS_BOOTSTRAP_PW` instead of a hardcoded string).
  Not part of the Vault migration itself.
- AppRole's `secret_id` currently has no TTL (`secret_id_ttl` unset) —
  fine for a single-operator homelab, worth a rotation policy later if
  this cluster's threat model ever changes.
