# Project status — GitOps Galaxy

Snapshot as of 2026-07-05. This reflects what has actually been verified in
the running cluster and pushed to `origin/main`, not just what's been
attempted.

## Fully done and verified

- **Namespaces** (`manifests/namespaces/`): `app`, `database`, `argocd`, each
  with `ResourceQuota` and `LimitRange` applied.
- **Database**: PostgreSQL installed via Bitnami Helm chart
  (`manifests/database/values.yaml`), with a connectivity test Job
  (`manifests/database/db-test-job.yaml`) confirmed passing.
- **Custom Helm chart** (`charts/sorcery-chart/`): backend + frontend
  Deployments, Services, ConfigMap, HPA, and Ingress — deployed and Healthy.
- **ArgoCD installed** via Helm, all pods `1/1 Running`.
- **ArgoCD `Application` resource** (`manifests/argocd/application.yaml`)
  applied and confirmed **Synced/Healthy**, with all 4 sync behaviors
  verified present and doing what they claim:
  - `prune: true` (automated)
  - `selfHeal: true` (automated)
  - `syncOptions: [PruneLast=true, ApplyOutOfSyncOnly=true]`
  - `ignoreDifferences` on `/spec/replicas` for the Deployment (so HPA-managed
    replica counts don't fight the declared spec)
- **ArgoCD RBAC reviewed and documented** (`manifests/argocd/RBAC.md`):
  confirmed the application-controller/server ClusterRoles are the Helm
  chart's stock cluster-admin-equivalent default (no custom overrides
  supplied), and confirmed `argocd-rbac-cm`'s `policy.default: ""` is a
  secure deny-by-default posture. Written up explicitly so it's a examined
  decision, not an unexamined default, for review.
- **Image Updater — confirmed working end-to-end with a live test**, not
  just configuration inspection:
  - Local ArgoCD account `image-updater` (apiKey capability), token issued
    and verified live in `argocd-image-updater-secret` (JWT `sub`/`jti`
    cross-checked against `argocd account list`).
  - Git write-back credentials (`argocd/git-creds` secret) confirmed correct
    (`username`/`password` keys, username matches the Gitea account).
  - **Live test performed**: deliberately downgraded
    `frontend.image.tag` to `1.27.3` (commit `14b8d9d`), watched ArgoCD sync
    it live, watched `argocd-image-updater` detect the outdated patch,
    update the live Application spec, and write back a correcting commit
    (`f269240`, authored by `argocd-image-updater <noreply@argoproj.io>`)
    bumping it back to `1.27.5` per the `semver` update strategy on
    `nginx:1.27.x`. This is the second time the pipeline has self-corrected
    a version drift (first at `36870d9`).
  - Everything pushed and merged; working tree clean, local `main` matches
    `origin/main`.

## Flagged but not urgent

- **Image Updater RBAC is broader than necessary**: `role:image-updater` in
  `argocd-rbac-cm` grants `applications, get/update, */*` — unscoped to any
  project or app name, so it can act on any Application, not just
  `sorcery-app`. Functionally fine today (single app, single project), but
  worth tightening to a scoped rule (e.g. `sorcery-app` or
  `default/sorcery-app`) as a least-privilege cleanup before this pattern is
  reused for additional apps.

## Not started yet

- **CI/CD pipeline wiring to ArgoCD** — no CI config exists in the repo yet
  (no `.github/`, no pipeline definitions). Image builds/tag bumps into
  git currently only happen via the Image Updater's own write-back, not a
  CI pipeline.
- **Rollback strategy demonstration** — no rollback has been exercised or
  documented (e.g. `argocd app rollback`, or a git-revert-based rollback
  flow tied to the automated sync policy).
- **Multi-environment setup** — everything currently targets a single
  cluster/environment; no staging/prod split, no per-environment values
  overlays or separate Applications/ApplicationSets.
- **Vault** — no secrets management beyond raw Kubernetes Secrets
  (`git-creds`, `argocd-image-updater-secret`, etc.) exists. No Vault
  integration, no External Secrets Operator, nothing beyond plain `Secret`
  objects checked into the cluster (not into git).
- **README** — no top-level `README.md` describing the project, setup
  steps, or architecture for a new reader.
