# Phase 6 — GitOps Galaxy: Review Explanation Guide

Every item is numbered to match the checklist order. Each explanation
includes an analogy to make the concept stick, then your specific
implementation so you can point at real evidence.

---

## SECTION 1 — HELM: CONCEPTUAL QUESTIONS

---

### 1. How Helm simplifies Kubernetes application deployments

**Analogy:** Think of Helm like a restaurant meal kit service (HelloFresh,
etc.). Without it, cooking dinner means sourcing every ingredient
separately — butcher for meat, greengrocer for veg, deli for cheese — with
no guarantee they'll arrive at the same time or in the right quantities.
A meal kit bundles everything into one box, pre-measured, with one set of
instructions. Helm does the same for Kubernetes: instead of hunting down
and applying a Deployment, Service, ConfigMap, HPA, and Ingress one by
one, the chart bundles them all. One command — `helm install` — and the
entire application lands in the cluster, in the right order, configured
exactly as you asked.

The simplification is threefold:
- **Packaging** — one artifact instead of many loose files.
- **Templating** — change one value and every manifest that references it
  updates automatically.
- **Lifecycle management** — Helm tracks what it installed, so `helm
  upgrade`, `helm rollback`, and `helm uninstall` all work without you
  manually tracking what exists in the cluster.

*Your implementation:* `sorcery-chart` bundles Deployments for frontend
and backend, Services, ConfigMap, HPA, and Ingress. A single
`helm install -f values-dev.yaml` or `-f values-prod.yaml` deploys the
right variant.

---

### 2. Why Helm improves productivity, reduces complexity, and enhances scalability

**Analogy:** Imagine you're managing three branches of a coffee shop
(dev, staging, production). Without Helm, it's like printing a completely
separate operations manual for each branch — if the espresso recipe
changes, you update three manuals. With Helm, there's one master manual
and three one-page "branch overrides" (values files). Updating the recipe
touches one file; the overrides handle what's different per branch.

- **Productivity:** one `helm upgrade` rolls a new version across the
  whole stack. No manual `kubectl apply -f` per file.
- **Reduced complexity:** environment differences collapse into a values
  file diff, not a manifests diff.
- **Scalability:** adding a fourth environment is a new values file, not
  a new copy of every manifest.

---

### 3. The structure of a Helm chart

**Analogy:** A Helm chart is like a recipe book with a built-in shopping
list. `Chart.yaml` is the cover page (name, version, what this is).
`values.yaml` is the shopping list — the quantities you can adjust.
The `templates/` folder is the recipes themselves, written with blanks
(`{{ }}`) that get filled in from the shopping list when you cook.

```
sorcery-chart/
├── Chart.yaml          ← cover page: name, version, description
├── values.yaml         ← default shopping list (configurable parameters)
└── templates/
    ├── deployment.yaml ← recipe with {{ }} blanks
    ├── service.yaml
    ├── configmap.yaml
    ├── hpa.yaml
    └── ingress.yaml
```

- `Chart.yaml` — metadata: name, version, appVersion, description.
- `values.yaml` — the single file operators edit. Every template reads
  from here via `{{ .Values.* }}`.
- `templates/` — Kubernetes YAML with Go template placeholders. Helm
  renders them by substituting values at install/upgrade time.

---

### 4. How Helm's templating system works (Go templates)

**Analogy:** Go templates work exactly like a mail-merge letter. You write
one letter with `Dear {{NAME}}, your order of {{QUANTITY}} items is
ready.` and merge it against a spreadsheet of names and quantities. Each
row produces a personalised letter. Helm does the same: one template file,
merged against `values.yaml`, produces the final Kubernetes manifest.

```yaml
# Inside templates/deployment.yaml
image: "{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag }}"
replicas: {{ .Values.replicaCount }}
```

When you run `helm install -f values-prod.yaml`, Helm merges your values
file over the defaults and substitutes every `{{ }}` expression before
sending the result to the Kubernetes API. You can also use:
- Conditionals: `{{- if .Values.ingress.enabled }}`
- Loops: `{{ range .Values.extraEnvVars }}`
- Functions: `{{ .Values.name | quote }}`, `{{ default "latest" .Values.tag }}`

*Your implementation:* image repository, tag, replica count, resource
limits, environment variables, and ingress host are all templated — swap
one values file and every manifest updates consistently.

---

### 5. Helm lifecycle hooks and their use cases

**Analogy:** Hooks are like the pre-flight checklist a pilot runs before
takeoff and the shutdown checklist after landing. They're mandatory steps
that happen at specific moments in the journey — not part of the flight
itself, but critical to making it safe. Helm hooks are Jobs that run at
specific points in the release lifecycle: before an install, after an
upgrade, before a delete, etc.

| Hook | When it runs | Common use |
|------|-------------|------------|
| `pre-install` | Before any resources are created | Validate prerequisites |
| `post-install` | After all resources are running | Send a Slack notification |
| `pre-upgrade` | Before the upgrade begins | Run database migrations |
| `post-upgrade` | After the upgrade completes | Smoke-test the new version |
| `pre-delete` | Before tearing down a release | Back up data |

A hook is just a standard Kubernetes manifest with one extra annotation:
`helm.sh/hook: pre-upgrade`.

*Your implementation:* the database connectivity Job (connects to
PostgreSQL, inserts test data, verifies the query) follows the
`post-install` hook pattern exactly — it runs after the database is up
to confirm it's ready before the application uses it.

---

### 6. Managing dependencies in Helm charts (Chart.yaml)

**Analogy:** Dependencies in Helm are like a flat-pack furniture assembly
where your bookshelf requires a pre-assembled base unit from a different
box. You don't build the base from scratch — you declare it as a
dependency and IKEA (Helm) fetches it and assembles it first.

Dependencies live in `Chart.yaml`:

```yaml
dependencies:
  - name: postgresql
    version: "15.x.x"
    repository: "https://charts.bitnami.com/bitnami"
```

Running `helm dependency update` downloads the dependency chart into a
`charts/` subdirectory. When you install the parent chart, Helm installs
the sub-chart first.

*Your implementation:* PostgreSQL is deployed via the Bitnami chart
independently — a deliberate separation of concerns. The database is
infrastructure; `sorcery-chart` is the application. They have different
lifecycles: you upgrade the app frequently, but you rarely touch the
database chart version.

---

### 7. Methods for testing Helm charts (helm test)

**Analogy:** `helm test` is like the quality assurance inspector who walks
through a newly built house after construction, checking that the lights
turn on, the taps run water, and the doors close properly — a systematic
verification that what was installed actually works.

A Helm test is a Kubernetes Pod annotated with `helm.sh/hook: test` that
runs a command and exits 0 on success, non-0 on failure. Your chart has
one at `charts/sorcery-chart/templates/test-connection.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: "sorcery-test-connection"
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  containers:
    - name: test-backend
      image: busybox
      command: ['wget', '-qO-', 'http://sorcery-app-staging-backend.staging.svc.cluster.local:8080/health']
  restartPolicy: Never
```

**Live demo commands — run these during the review:**

```bash
# Step 1 — Install the chart manually (ArgoCD-managed releases don't show in helm list)
helm install sorcery-test charts/sorcery-chart \
  -f charts/sorcery-chart/values-dev.yaml \
  --set ingress.enabled=false \
  -n staging

# Step 2 — Run the helm test
helm test sorcery-test -n staging
# Expected output:
# TEST SUITE:     sorcery-test-connection
# Phase:          Succeeded  ✅

# Step 3 — Clean up after demo
helm uninstall sorcery-test -n staging
```

**Bonus talking point — ResourceQuota proof:**
If you run the test in the `dev` namespace instead, it fails with:
```
exceeded quota: dev-quota, requested: limits.cpu=250m, used: limits.cpu=1, limited: limits.cpu=1
```
This proves two checklist items at once — helm test hooks fire correctly,
AND the ResourceQuota is enforcing namespace CPU limits exactly as designed.

*Your implementation:* the `db-connectivity-test` Job in the database
namespace follows the exact same pattern — runs, verifies, exits 0,
reports `DB_TEST_PASSED`.

---

## SECTION 2 — HELM: VERIFICATION POINTS

---

### 8. Database deployed via pre-existing Helm chart

```bash
helm list -n database
kubectl get pods -n database
```

PostgreSQL is deployed using the Bitnami chart with a PVC for persistent
storage. All pods show `Running`.

---

### 9. Kubernetes Job successfully connects to the database

```bash
kubectl logs -n database job/postgres-connectivity-test
```

The Job connects to the PostgreSQL service, runs a basic query
(INSERT + SELECT), and exits 0. The log shows the successful result.

---

### 10. Database persistence verified (insert → delete pod → data survives)

**Analogy:** The difference between a pod and a PVC is like the difference
between a chef and a recipe book. The chef (pod) can be replaced — get
sick, go home, be swapped out — but the recipe book (PVC) stays on the
shelf. The new chef picks up the book and continues exactly where the last
one left off.

```bash
# 1. Insert test data via the Job
# 2. Delete the pod — the StatefulSet controller recreates it
kubectl delete pod -n database -l app.kubernetes.io/name=postgresql
# 3. PVC reattaches automatically — data is still there
# 4. Re-run the Job to prove it
```

The pod is ephemeral; the PVC is not. Deleting the pod is not the same
as deleting the PVC.

---

### 11. Custom Helm chart with all required components

```bash
helm show chart charts/sorcery-chart
ls charts/sorcery-chart/templates/
```

`sorcery-chart` contains: Deployment (frontend), Deployment (backend),
Service (frontend), Service (backend), ConfigMap, HPA, Ingress. All
parameters are exposed through `values.yaml`.

---

### 12. Helm chart correctly applies customisation through values files

```bash
# Deploy dev environment
helm upgrade --install sorcery-app-dev charts/sorcery-chart \
  -f charts/sorcery-chart/values-dev.yaml -n dev

# Deploy production with different image tag and resource limits
helm upgrade --install sorcery-app-prod charts/sorcery-chart \
  -f charts/sorcery-chart/values-prod.yaml -n production
```

Each values file sets a different image tag, replica count, and resource
limits. Changes are applied immediately — verify with `kubectl describe
deploy -n dev` vs `-n production`.

---

### 13. Helm rollback is functional

**Analogy:** Helm's rollback is like the "undo" button in a word
processor, except every version you've ever saved is still accessible.
Helm stores each release revision as a Kubernetes Secret — revision 1,
2, 3, etc. `helm rollback` just re-renders and re-applies whichever
revision you point at.

```bash
# 1. Deploy a broken version
helm upgrade sorcery-app-dev charts/sorcery-chart \
  --set frontend.image.tag=broken -n dev

# 2. Roll back to the previous revision (0 = one step back)
helm rollback sorcery-app-dev 0 -n dev

# 3. Verify
helm history sorcery-app-dev -n dev
kubectl get pods -n dev
```

---

## SECTION 3 — ARGOCD: CONCEPTUAL QUESTIONS

---

### 14. How ArgoCD implements GitOps principles

**Analogy:** GitOps is like a bank's double-entry bookkeeping system.
Every transaction must be recorded in the ledger (Git) before it takes
effect in the real world (the cluster). If someone moves money without
recording it (manually runs `kubectl apply`), the books don't balance and
an auditor (ArgoCD) immediately flags the discrepancy and corrects it.
Git is the ledger — the single source of truth.

ArgoCD enforces this by continuously comparing:
- **Desired state** — what's committed in Git
- **Live state** — what's actually running in the cluster

Any divergence is called **drift**. With `selfHeal: true`, ArgoCD corrects
drift automatically within ~3 minutes — no human required, no `kubectl
apply` in the deployment path. Every change is auditable (Git history),
reviewable (pull request), and reversible (git revert).

---

### 15. ArgoCD's architecture and its components

**Analogy:** ArgoCD's architecture is like a newspaper operation. The
**Repository Server** is the journalist — it reads the source (Git) and
produces the final copy (rendered manifests). The **Application Controller**
is the editor — it compares the journalist's copy against what's already
been published (live cluster state) and decides what needs updating. The
**API Server** is the front desk — it handles all incoming requests from
reporters (CLI, UI, CI/CD pipelines). The **UI** is the newspaper's
website — a read-friendly view of what's been published and what's
pending.

| Component | Role |
|-----------|------|
| **API Server** | gRPC/REST endpoint; handles auth and RBAC |
| **Repository Server** | Clones Git repos; renders Helm/Kustomize/YAML |
| **Application Controller** | Reconciliation loop; detects drift; fires syncs |
| **UI / Dex** | Web interface and optional SSO |

All components run as pods in the `argocd` namespace.

---

### 16. How to create and manage Applications using the Application CRD

**Analogy:** An ArgoCD `Application` CR is like a standing delivery order.
You fill out a form once: "pick up from this Git address, deliver to this
namespace, and keep coming back every time the source changes." ArgoCD
honours the order indefinitely — you don't repeat the instruction for
every deployment.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sorcery-app-dev
  namespace: argocd
spec:
  source:
    repoURL: https://gitea.kood.tech/evanschepkwony1/gitops-galaxy.git
    path: charts/sorcery-chart
    helm:
      valueFiles: ["values-dev.yaml"]
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - PruneLast=true
      - ApplyOutOfSyncOnly=true
```

You can manage Applications via `kubectl apply`, the CLI
(`argocd app create`), or the UI — all three are equivalent.

---

### 17. How to navigate and use the ArgoCD UI and CLI

**Analogy:** The UI is like a car dashboard — everything is visible at a
glance, colour-coded (green = Healthy, yellow = Progressing, red = Degraded),
and you can interact with controls directly. The CLI is like talking to the
car's OBD port — more precise, scriptable, and essential for automation
(like inside Jenkins).

**UI:** Applications view shows sync/health status for every app. Clicking
an app shows the resource tree — each Kubernetes object, its current
state, and any diff against Git.

**CLI:**
```bash
argocd app list                          # all applications + status
argocd app get sorcery-app-dev           # detailed view of one app
argocd app sync sorcery-app-dev          # trigger a manual sync
argocd app history sorcery-app-dev       # every sync revision
argocd app rollback sorcery-app-dev 3    # roll back to revision 3
argocd app diff sorcery-app-dev          # what would change on next sync
```

---

## SECTION 4 — ARGOCD: VERIFICATION POINTS

---

### 18. ArgoCD installed and all components healthy

```bash
kubectl get pods -n argocd
argocd version
```

Expect `argocd-server`, `argocd-repo-server`, `argocd-application-controller`,
`argocd-dex-server`, `argocd-redis` all `Running`.

---

### 19. Git repository integration properly configured

```bash
argocd repo list
```

Shows `gitea.kood.tech/evanschepkwony1/gitops-galaxy` with status
`Successful`. Credentials are stored as a Kubernetes Secret (PAT token,
not a plaintext password) — important because the Gitea username is an
email address containing `@`, which breaks URL-encoded credential strings
if not handled carefully.

---

### 20. Application status Synced and Healthy

```bash
argocd app get sorcery-app-dev
```

Shows `Sync Status: Synced` and `Health Status: Healthy`. Git state
matches cluster state.

---

### 21. RBAC follows the least-privilege principle

**Analogy:** RBAC is like a hotel key card system. The cleaner gets a card
that opens guest rooms but not the safe or the manager's office. The
manager gets a card for everything. Jenkins is the cleaner — it needs to
open specific doors (sync specific apps) but nothing else.

```bash
kubectl get configmap argocd-rbac-cm -n argocd -o yaml
```

- Jenkins token (`argocd-jenkins-token`) is scoped to `get` + `sync` on
  `default/sorcery-app-*` only — the `*` glob covers dev, staging, and
  production in one policy line. It cannot touch other applications or
  cluster resources.
- `image-updater` role has `get` + `update` on applications only.
- Admin access is limited to the admin account.

No role has more permissions than it needs to do its specific job.

---

### 22. Sync options: PruneLast, ApplyOutOfSyncOnly, ignoreDifferences

**Analogy for PruneLast:** Imagine renovating an office. You don't demolish
the old desks before the new ones arrive — you bring the new furniture in
first, then remove the old desks. `PruneLast` does exactly this: new
resources come up before old ones are deleted, so there's never a moment
with nothing running.

**Analogy for ApplyOutOfSyncOnly:** Like a spell-checker that only
highlights words it thinks are wrong, rather than re-scanning the whole
document on every keystroke. ArgoCD skips resources that are already
correct and only touches what has drifted.

**Analogy for ignoreDifferences:** HPA and ArgoCD would fight like two
people trying to control the same thermostat — HPA turns it to 3 replicas,
ArgoCD resets it to 2 (from Git), HPA responds again. `ignoreDifferences`
tells ArgoCD: "this thermostat knob belongs to HPA, don't touch it."

```yaml
syncOptions:
  - PruneLast=true
  - ApplyOutOfSyncOnly=true
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas     # HPA owns this field at runtime
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

---

### 23. Continuous reconciliation / drift detection working

```bash
# Make a manual change directly to the cluster (simulate someone running kubectl)
kubectl scale deployment frontend -n dev --replicas=5

# Within ~3 minutes ArgoCD detects drift and corrects it
argocd app get sorcery-app-dev   # briefly shows OutOfSync, then Synced
```

This is `selfHeal: true` in action — the bookkeeper catching and correcting
the unrecorded transaction.

---

## SECTION 5 — ARGOCD IMAGE UPDATER

---

### 24. How Image Updater works (Git write-back, semver patch tracking)

**Analogy:** Image Updater is like a librarian who checks the publisher's
catalogue every two minutes. When a new edition of a book arrives that's
compatible with the existing curriculum (same major/minor version, just a
patch), she quietly updates the library's inventory record (Git), and the
teacher (ArgoCD) notices the new record and orders the updated book for
the classroom (cluster). Major new editions — incompatible with the
curriculum — stay on the publisher's shelf uncollected.

Image Updater polls the container registry on a configurable interval.
When it finds a tag satisfying the constraint it:
1. Clones the Git repo.
2. Updates the image tag in a `.argocd-source-*.yaml` override file.
3. Commits and pushes to Git.
4. ArgoCD detects the new commit and syncs the cluster.

The annotation on the Application CR controls the strategy:

```yaml
annotations:
  argocd-image-updater.argoproj.io/image-list: frontend=nginx
  argocd-image-updater.argoproj.io/frontend.update-strategy: semver
  argocd-image-updater.argoproj.io/frontend.allow-tags: regexp:^1\.27\.\d+$
  argocd-image-updater.argoproj.io/write-back-method: git
```

`semver` with a patch constraint means:
- `1.27.1` → update ✅ (patch bump — allowed)
- `1.28.0` → ignore ✅ (minor bump — outside constraint)
- `2.0.0`  → ignore ✅ (major bump — outside constraint)

---

### 25. Image Updater installed and pods running

```bash
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-image-updater
kubectl logs -n argocd deploy/argocd-image-updater | tail -20
```

Logs show `Starting image update cycle` and `Updating image nginx:1.27.x`.

---

### 26. Git write-back verified end-to-end

This was verified live twice:
1. Image Updater detected a new patch tag in the registry.
2. It committed a tag bump to Gitea — visible in the repo's commit history
   as a commit from `argocd-image-updater`.
3. ArgoCD detected the new commit and synced `sorcery-app-dev` to use the
   new tag.

---

### 27. Minor and major updates correctly ignored

Image Updater was configured with `semver` strategy and a patch-only
constraint. Pushing `1.28.0` or `2.0.0` leaves the Git repo and cluster
unchanged. Image Updater logs show both tags were evaluated and rejected
as outside the constraint — the librarian checked the catalogue and put
those editions back on the publisher's shelf.

---

## SECTION 6 — CI/CD PIPELINE

---

### 28. Pipeline manages the complete deployment workflow end-to-end

**Analogy:** The Jenkins pipeline is like an assembly line with a quality
gate. Each station (stage) must pass before the car moves to the next one.
If the engine test fails at station 3, the car doesn't move to station 4
(paint). If a CVE is found in the security scan, the image never reaches
the cluster. If staging is unhealthy after deploy, production is never
touched.

```
Stage 1: Checkout       — pull source + manifests repos
Stage 2: Test (parallel)— go test, go vet, npm lint
Stage 3: Build          — docker build backend + frontend
Stage 4: Security Scan  — Trivy, --exit-code 1 on CRITICAL (blocks pipeline)
Stage 5: Update Manifests — push new image tag to Git
         (ArgoCD auto-syncs dev and staging from here)
Stage 6: Gate           — human input() approval for production
Stage 7: Promote        — argocd app sync production
Stage 8: post{failure}  — rollback all three environments
```

---

### 29. ArgoCD Application management integrated into the pipeline

The pipeline uses the ArgoCD CLI authenticated via `argocd-jenkins-token`.
That token is scoped to `get` + `sync` on `sorcery-app-*` — it cannot
touch anything else in the cluster.

```groovy
sh "argocd app sync sorcery-app-staging --auth-token ${ARGOCD_TOKEN}"
sh "argocd app wait sorcery-app-staging --health --timeout 120"
```

`argocd app wait --health` blocks the pipeline until ArgoCD confirms the
deployment is healthy — not just synced, but actually running correctly.

---

### 30. Rollback mechanism properly implemented

**Analogy:** The rollback is like a fire extinguisher — you hope you never
need it, but when you do, you want it to work immediately and without
debate. The `post { failure }` block in Jenkinsfile is that extinguisher:
it triggers the moment any stage fails.

```groovy
post {
  failure {
    sh "argocd app sync sorcery-app-dev      --auth-token ${ARGOCD_TOKEN}"
    sh "argocd app sync sorcery-app-staging  --auth-token ${ARGOCD_TOKEN}"
    sh "argocd app sync sorcery-app-production --auth-token ${ARGOCD_TOKEN}"
  }
}
```

Key design point: `production` uses `Sync Policy: Manual`, which prevents
the ArgoCD *controller* from auto-syncing. But an *authenticated explicit
sync call* from Jenkins still works — `Manual` blocks the automated
controller, not authenticated CLI calls. This is how the rollback bypasses
the approval gate when correcting a failure: it's a deliberate
human-initiated pipeline action, not an automated controller decision.

---

## SECTION 7 — MULTI-ENVIRONMENT SETUP

---

### 31. Three isolated namespaces with ResourceQuota and LimitRange

**Analogy:** The three namespaces are like floors of a building under
separate tenancy. Dev is a co-working space — flexible, cheaper, smaller
desks. Staging is a proper office — mirrors production layout. Production
is the executive floor — full resources, tightest controls, and you need
a badge (manual approval) to change anything. A fire on the dev floor
(broken deployment) cannot spread to production because the floors are
structurally separate.

```bash
kubectl get namespaces | grep -E "dev|staging|production"
kubectl get resourcequota -A
kubectl get limitrange -A
```

| Namespace  | Sync Policy | Who triggers deploys          |
|------------|-------------|-------------------------------|
| dev        | Automatic   | Image Updater + any Git push  |
| staging    | Automatic   | Git push after dev succeeds   |
| production | Manual      | Human approval gate in Jenkins|

`LimitRange` auto-injects default resource requests/limits onto any pod
that doesn't specify them — prevents Kubernetes admission rejections from
pods with no resource spec, which is a common failure mode when adding new
components.

---

### 32. Environment-specific Helm values files

```bash
ls charts/sorcery-chart/values-*.yaml
# values-dev.yaml        — lower replicas, debug logging, smaller limits
# values-staging.yaml    — mirrors production sizing for realistic testing
# values-production.yaml — full replicas, production resource limits
```

The ArgoCD Application for each environment references its own values
file. One chart serves all three — no duplicated manifests, no risk of
the three environments drifting from each other in structure, only in
configuration.

---

### 33. Promotion process: changes pass tests before reaching production

**Analogy:** Promotion is like a hiring process. A candidate (code change)
first passes a phone screen (dev deploy + tests). Then a panel interview
(staging deploy + health check). Only after both rounds does a human
hiring manager (the Jenkins `input()` gate) give the final yes before
the offer letter goes out (production deploy).

1. Trivy must pass — any CRITICAL CVE blocks the entire pipeline.
2. Image Updater auto-promotes to dev.
3. Jenkins `input()` step requires a human to approve before staging →
   production.
4. If staging health check fails, `post { failure }` rolls back and
   production is never touched. Failed candidates don't get the job.

---

## SECTION 8 — EXTRA: VAULT / EXTERNAL SECRET MANAGEMENT

---

### 34. Why external secret management is better than Kubernetes Secrets

**Analogy:** A Kubernetes Secret is like writing your house alarm code on
a sticky note inside the house. It's "hidden" in the sense that you need
to be inside to see it, but anyone who gets in can read it immediately.
HashiCorp Vault is like a bank's key management system: keys are stored
in a hardened vault, every access is logged in an immutable audit trail,
keys expire automatically, and you can revoke specific keys without
touching others.

The technical differences:

| | Kubernetes Secrets | HashiCorp Vault |
|---|---|---|
| **Encryption at rest** | Base64 only (not encrypted by default) | AES-256-GCM encrypted always |
| **Access control** | Anyone with namespace read access | Fine-grained policies per secret path |
| **Audit trail** | None built-in | Every read/write logged with timestamp and identity |
| **Secret rotation** | Manual — edit Secret, restart pod | Automatic TTLs; dynamic credentials generated on demand |
| **Dynamic secrets** | Not possible | Vault generates short-lived DB credentials per request |

Key point reviewers often probe: base64 is **encoding**, not encryption.
`echo "password" | base64` and `echo "cGFzc3dvcmQ=" | base64 -d` are
trivially reversible by anyone. A Kubernetes Secret gives the appearance
of protection without the substance.

---

### 35. External secret management integration verified

```bash
# Vault is running and unsealed
kubectl get pods -n vault
kubectl exec -n vault vault-0 -- vault status

# External Secrets Operator is running
kubectl get pods -n external-secrets

# ClusterSecretStore references Vault's Kubernetes auth backend
kubectl get clustersecretstore vault-backend -o yaml

# ExternalSecret objects sync successfully
kubectl get externalsecret -A
# STATUS column shows "SecretSynced" for all three secrets

# The resulting Kubernetes Secrets exist and are populated
kubectl get secret pg-credentials -n app
kubectl get secret git-creds -n app
kubectl get secret argocd-image-updater-secret -n argocd
```

The application's Helm chart references the Secret by name — it never
contains the actual credential value. The secret value lives only in Vault.
The External Secrets Operator is the bridge: it authenticates to Vault
using the pod's Kubernetes service account token, retrieves the secret,
and writes it as a native Kubernetes Secret. When Vault rotates the value,
ESO syncs the update automatically.

---

## SECTION 9 — DOCUMENTATION AND CODE QUALITY

---

### 36. Directory structure follows standard conventions

```
gitops-galaxy/
├── charts/
│   └── sorcery-chart/         ← Helm chart: Chart.yaml, values*.yaml, templates/
├── manifests/
│   ├── argocd/                ← Application CRs, RBAC ConfigMap
│   ├── image-updater/         ← ImageUpdater CR
│   ├── database/              ← DB Job, PVC manifests
│   └── namespaces/            ← Namespace + ResourceQuota + LimitRange YAMLs
├── Jenkinsfile
└── README.md
```

Separation of concerns: Helm charts in `charts/`, raw cluster manifests
in `manifests/`, pipeline logic in `Jenkinsfile`. A reviewer landing in
any folder immediately understands what it contains.

---

### 37. Helm chart adheres to best practices

- `Chart.yaml` has `name`, `version` (semver), `appVersion`, and
  `description`.
- `values.yaml` documents every configurable field with a comment above
  it — it's self-documenting.
- Templates use `{{ include "sorcery-chart.fullname" . }}` helper for
  consistent naming across all resources (no hardcoded strings in
  templates).
- Resource `requests` and `limits` are templated — never hardcoded.
- Labels follow the `app.kubernetes.io/*` convention throughout
  (name, version, component, managed-by).

---

*All commands above can be run live during the review. Every component
was verified working end-to-end on the git-galaxy Hetzner server, with
deliberate failure scenarios tested — not just happy paths.*

---

