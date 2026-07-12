# Project status — GitOps Galaxy

Snapshot as of 2026-07-06. This reflects what has actually been verified in
the running cluster and pushed to `origin/main`, not just what's been
attempted.

## Fully done and verified

- **Namespaces** (`manifests/namespaces/`): `database`, `argocd`, `dev`,
  `staging`, `production`, each with `ResourceQuota` and `LimitRange`
  sized `dev < staging <= production`. The original single `app` namespace
  and its `sorcery-app` Application were retired once the three per-env
  Applications were confirmed working (see multi-environment section
  below) — there is no `app` namespace anymore.
- **Database**: PostgreSQL installed via Bitnami Helm chart
  (`manifests/database/values.yaml`), with a connectivity test Job
  (`manifests/database/db-test-job.yaml`) confirmed passing.
- **Custom Helm chart** (`charts/sorcery-chart/`): backend + frontend
  Deployments, Services, ConfigMap, HPA, and Ingress. Values are split into
  a shared base (`values.yaml`) plus `values-dev.yaml`/`values-staging.yaml`/
  `values-production.yaml` overlays for namespace, ingress host, and
  replica/HPA sizing — verified with `helm template`/`helm lint` against
  all three before rollout.
- **ArgoCD installed** via Helm, all pods `1/1 Running`. Reachable from
  outside the cluster via a stable NodePort (`manifests/argocd/argocd-server-nodeport.yaml`,
  `192.168.49.2:30443`) instead of an ad-hoc `kubectl port-forward` (which
  died every time the cluster restarted).
- **Three ArgoCD Applications** (`sorcery-app-dev`, `sorcery-app-staging`,
  `sorcery-app-production`), replacing the original single `sorcery-app`.
  All confirmed **Synced/Healthy** live. `dev`/`staging` are automated
  (`prune`+`selfHeal`); **`production` deliberately has no `automated`
  block** — confirmed empirically that applying it alone deploys nothing
  (`Health: Missing`) until explicitly synced, which only the Jenkins
  pipeline's post-approval stage does. All three keep the same
  `syncOptions`/`ignoreDifferences` (`PruneLast`, `ApplyOutOfSyncOnly`,
  ignoring Deployment `/spec/replicas` since HPA owns it).
- **ArgoCD RBAC reviewed and documented** (`manifests/argocd/RBAC.md`):
  cluster permissions (application-controller/server ClusterRoles) are the
  Helm chart's stock cluster-admin-equivalent default, examined and
  accepted as-is. `argocd-rbac-cm`'s `policy.default: ""` is a secure
  deny-by-default posture. Three access identities now documented:
  `role:image-updater` (broad, `*/*`), `role:jenkins-ci` (scoped to the
  glob `default/sorcery-app-*`), and the `jenkins-ci` Kubernetes
  ServiceAccount (scoped to `create`/`update` on `applications.argoproj.io`
  in the `argocd` namespace only — verified with `kubectl auth can-i`).
- **Image Updater — confirmed working end-to-end with two live tests**:
  - Local ArgoCD account `image-updater` (apiKey), token verified live via
    JWT `sub`/`jti` cross-check.
  - Git write-back credentials (`argocd/git-creds` secret) confirmed
    correct.
  - **Live test #1**: deliberately downgraded `frontend.image.tag` to
    `1.27.3`, watched Image Updater detect and self-correct it back to
    `1.27.5` via a write-back commit (`f269240`).
  - **Retargeted to `sorcery-app-dev`** (not production) as part of the
    multi-environment work, so its automatic commits flow through the
    same dev → staging → approval → production gate as any human-driven
    change, rather than bypassing straight to production.
- **CI/CD pipeline (Jenkins)**: runs as a Docker container on the host
  (not in-cluster), attached to the `minikube` Docker network. Credentials
  (Gitea token, a scoped kubeconfig, an ArgoCD token) live in Jenkins'
  encrypted credential store — never as container env vars or plaintext
  files, proven via a real pipeline run with `withCredentials` bindings.
  The `Jenkinsfile` (repo root) implements: checkout → commit & push a
  manifest marker → deploy dev (sync + wait) → deploy staging (sync +
  wait) → manual **`input` approval gate** ("Promote to production?") →
  deploy production (sync + wait) → `post{failure}`: `git revert` the
  commit, push, and re-sync all three environments.
  - **Rollback proven live** (pre-multi-env version): deliberately broke
    the frontend tag as part of the pipeline's own commit, watched
    `argocd app wait --health --timeout 300` genuinely time out, watched
    `post{failure}` fire, revert (`9d2f065`), push, and re-sync restore
    `Healthy` — confirmed against the live cluster, not just the log.
  - **Multi-env promotion proven live**: a real build ran dev → staging
    (both auto-synced to `Healthy`) → paused at the approval gate →
    approved via the Jenkins API → production deployed and reached
    `Healthy`, with `Sync Policy: Manual` confirmed unchanged throughout
    (ArgoCD never auto-deployed it).
  - Aborting at the approval gate produces Jenkins result `ABORTED`, not
    `FAILURE` — `post{failure}` does not fire in that case, so declining
    to promote doesn't spuriously revert an otherwise-healthy staging
    deployment.

- **Vault installed** (`manifests/vault/`): official `hashicorp/vault`
  Helm chart, single-node standalone with **integrated Raft storage**
  (persistent, `dataStorage` size `2Gi`), TLS disabled on the listener
  (plaintext HTTP — acceptable for this single-operator minikube homelab),
  ClusterIP-only (no NodePort yet). Agent Injector disabled — not needed
  until pod-level secret injection is required; External Secrets Operator
  (when added) will talk to the Vault API directly.
  - Real init/unseal performed (`vault operator init -key-shares=5
    -key-threshold=3`, unsealed with 3 of 5 keys) — not dev mode. Root
    token and unseal keys are **not committed anywhere in this repo**;
    same "reference by name, never commit the value" convention as
    `pg-credentials`/`git-creds`. They live only in the operator's secure
    offline storage.
  - Confirmed live: `vault-0` `1/1 Running`, `vault status` shows
    `Initialized: true`, `Sealed: false`, `Storage Type: raft`,
    `HA Mode: active`. A smoke-test Job
    (`manifests/vault/vault-status-test-job.yaml`, mirrors
    `database/db-test-job.yaml`'s pattern) confirmed `VAULT_TEST_PASSED`
    from inside the cluster.
  - Scope of this pass was deliberately narrow: **just the install**, as
    the foundation for later work — see below.

## Flagged but not urgent

- **Image Updater RBAC is broader than necessary**: `role:image-updater`
  still grants `applications, get/update, */*` — unscoped to any
  project/app name, unlike `role:jenkins-ci`'s tighter glob-scoped pattern.
  Functionally fine today; worth tightening to match the `jenkins-ci`
  pattern as a later least-privilege cleanup.
- **No scoped human-facing ArgoCD role** beyond the built-in `admin`
  superuser — fine for a single-operator project, named gap if more humans
  need access later.

## Not started yet

- **Vault secrets engine / ESO integration** — Vault itself is installed
  (see above) but nothing reads from it yet. Existing raw Kubernetes
  Secrets (`git-creds`, `argocd-image-updater-secret`, the Jenkins
  credential store, etc.) are still the only secrets management in place.
  Still needed: enable a KV secrets engine, a Kubernetes auth method +
  policies, install External Secrets Operator, and migrate the existing
  Secrets over one at a time.
- **README** — no top-level `README.md` describing the project, setup
  steps, or architecture for a new reader.
