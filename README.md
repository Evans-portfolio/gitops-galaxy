# GitOps Galaxy

A minikube-based GitOps homelab: a toy backend/frontend app deployed to
three environments (dev/staging/production) via ArgoCD, promoted through
a Jenkins pipeline with a manual production gate, with automated image
updates and Vault-backed secrets management end to end.

For the full, dated history of what's actually been built and verified
live (as opposed to just attempted), see [`NOTES.md`](NOTES.md) — that's
the living source of truth for project status. This README is the
onboarding doc: what the pieces are and how they fit together.

## Architecture

```
Gitea repo (this repo)
   |
   |  git push (Jenkins, via Vault-backed creds)
   v
Jenkins (Docker container on host)
   |  kubectl apply Application CRs + argocd app sync/wait (Vault-backed creds)
   v
ArgoCD (in-cluster)  <---- ArgoCD Image Updater (watches frontend image tag,
   |                        writes back to charts/sorcery-chart/values.yaml)
   |  Helm render + sync
   v
charts/sorcery-chart -> dev / staging / production namespaces
   |
   v
Postgres (database namespace)

Vault (in-cluster) <---- External Secrets Operator (K8s Secrets: pg-credentials,
   ^                      git-creds, argocd-image-updater-secret)
   |
   +---- Vault Jenkins plugin (Jenkins' own 3 credentials, host-side)
```

- **Namespaces**: `database`, `argocd`, `dev`, `staging`, `production`,
  `vault`, `external-secrets` — each with a `ResourceQuota`/`LimitRange`
  sized `dev < staging <= production`.
- **App**: `charts/sorcery-chart` — a backend (`hashicorp/http-echo`) and
  frontend (`nginx`) Helm chart, with a shared `values.yaml` plus
  per-environment overlays (`values-dev.yaml`, `values-staging.yaml`,
  `values-production.yaml`) controlling namespace, ingress host, and
  replica/HPA sizing.
- **Database**: PostgreSQL via the Bitnami Helm chart
  (`manifests/database/`), credentials Vault-backed.
- **ArgoCD**: three `Application` CRs (`sorcery-app-dev/staging/production`,
  `manifests/argocd/`), reachable outside the cluster via a stable
  NodePort rather than `kubectl port-forward`. `dev`/`staging` auto-sync;
  **`production` requires an explicit sync**, only triggered by the
  Jenkins pipeline's post-approval stage.
- **ArgoCD Image Updater**: watches the frontend image tag on
  `sorcery-app-dev` and commits version bumps back to
  `charts/sorcery-chart/values.yaml` via git write-back — flows through
  the same dev → staging → approval → production gate as any human change.
- **Jenkins**: runs as a Docker container on the host (not in-cluster),
  driving the `Jenkinsfile` pipeline: checkout → commit & push a manifest
  marker → deploy dev (sync + wait) → deploy staging (sync + wait) →
  manual approval gate → deploy production (sync + wait) → on failure,
  revert and re-sync all three environments.
- **Vault + External Secrets Operator**: all application secrets are
  Vault-backed. K8s-native secrets (`pg-credentials`, `git-creds`,
  `argocd-image-updater-secret`) sync via ESO's `ClusterSecretStore`;
  Jenkins' own three credentials (which ESO can't reach, since Jenkins
  isn't in-cluster) are backed by the HashiCorp Vault Jenkins plugin
  instead, under their original credential IDs.

## Repo layout

```
charts/sorcery-chart/       First-party app chart (backend + frontend), per-env values overlays
manifests/namespaces/       Namespace + ResourceQuota + LimitRange definitions
manifests/database/         Bitnami Postgres values + connectivity test Job
manifests/argocd/           Application CRs, RBAC audit doc, NodePort, per-secret ExternalSecrets
manifests/image-updater/    ArgoCD Image Updater CR
manifests/jenkins/          Jenkins' in-cluster ServiceAccount (for kubectl apply access)
manifests/vault/            Vault Helm values, policies, RBAC binding, integration docs
manifests/external-secrets/ ESO Helm values, ClusterSecretStore, round-trip test docs
Jenkinsfile                 The CI/CD pipeline definition
NOTES.md                    Dated project status — what's verified live vs. attempted
```

## Prerequisites

- A running minikube cluster (`minikube start`).
- `kubectl`, `helm`, `vault` CLI, `argocd` CLI.
- Docker, for the Jenkins container (runs on the `minikube` Docker
  network, not in-cluster).

## Bootstrapping order

Everything here was installed imperatively (no bootstrap script exists —
see "Not started yet" candidates in `NOTES.md` if that changes); the
order that avoids dependency issues:

1. **Namespaces**: `kubectl apply -f manifests/namespaces/` (apply twice
   — `limitranges.yaml` alphabetically precedes `namespaces.yaml`, so a
   fresh namespace's LimitRange fails on the first pass and succeeds on
   the second).
2. **Database**: `helm install my-db bitnami/postgresql -n database -f manifests/database/values.yaml`
   (requires a pre-existing `pg-credentials` Secret, or apply it via Vault
   — see below).
3. **ArgoCD**: `helm install argocd argo-cd/argo-cd -n argocd`, then
   `kubectl apply -f manifests/argocd/argocd-server-nodeport.yaml` and
   the three `Application` CRs.
4. **ArgoCD Image Updater**: `helm install argocd-image-updater
   argo-cd/argocd-image-updater -n argocd`, then
   `kubectl apply -f manifests/image-updater/`.
5. **Vault**: `helm install vault hashicorp/vault -n vault -f manifests/vault/values.yaml`,
   then `vault operator init`/`unseal` (real, not dev mode — see
   `manifests/vault/values.yaml`'s comments). Root token and unseal keys
   are **never committed** — store them outside this repo.
6. **External Secrets Operator**: `helm install external-secrets
   external-secrets/external-secrets -n external-secrets -f manifests/external-secrets/values.yaml`,
   then `kubectl apply -f manifests/external-secrets/clustersecretstore.yaml`
   and each `*-externalsecret.yaml` under `manifests/argocd/`/`manifests/database/`.
   Full walkthrough (KV engine, Kubernetes auth, policies): `manifests/vault/ESO-INTEGRATION.md`.
7. **Jenkins**: run the Jenkins container attached to the `minikube`
   Docker network, install the `hashicorp-vault-plugin`, and configure it
   per `manifests/vault/JENKINS-INTEGRATION.md` (AppRole auth, Vault
   NodePort, the three Vault-backed credentials matching the
   `Jenkinsfile`'s existing credential IDs).

## Environments

| Environment | Namespace | Sync policy | Promoted by |
|---|---|---|---|
| dev | `dev` | Automated (prune + selfHeal) | Any push (Jenkins or Image Updater) |
| staging | `staging` | Automated (prune + selfHeal) | Jenkins pipeline, after dev is healthy |
| production | `production` | **Manual** — no `automated` block | Jenkins pipeline, only after the approval gate |

## Secrets

Nothing in this repo commits a real secret value. Every Secret is either:
- **ESO-managed** (`ClusterSecretStore/vault-backend`, Kubernetes auth):
  `pg-credentials`, `git-creds`, `argocd-image-updater-secret`. Each has
  a companion smoke-test Job (`*-test-job.yaml`) that proves the secret
  actually works against its real consumer (DB connection, Gitea API,
  ArgoCD API) — not just that ESO reports it synced.
- **Jenkins-native, but Vault-backed** (HashiCorp Vault Jenkins plugin,
  AppRole auth): `gitea-jenkins-token`, `argocd-jenkins-token`,
  `jenkins-kubeconfig`. See `manifests/vault/JENKINS-INTEGRATION.md`.

Vault policies are scoped per-consumer and widened deliberately, one path
at a time, as documented in `manifests/vault/policies/*.hcl`.

## Further reading

- [`NOTES.md`](NOTES.md) — dated status: what's done and verified live,
  what's flagged but not urgent, what's not started.
- [`manifests/argocd/RBAC.md`](manifests/argocd/RBAC.md) — ArgoCD's
  cluster permissions and access-policy audit.
- [`manifests/vault/ESO-INTEGRATION.md`](manifests/vault/ESO-INTEGRATION.md) —
  Vault ↔ External Secrets Operator wiring and the three K8s secret
  migrations.
- [`manifests/vault/JENKINS-INTEGRATION.md`](manifests/vault/JENKINS-INTEGRATION.md) —
  Vault ↔ Jenkins wiring and the Jenkins credential migration.
- [`manifests/external-secrets/README.md`](manifests/external-secrets/README.md) —
  reproducible ESO ↔ Vault round-trip smoke test.
