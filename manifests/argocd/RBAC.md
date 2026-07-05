# ArgoCD RBAC — current configuration and rationale

There are two distinct RBAC layers in play. This note documents both as a
deliberate, examined decision rather than an unexamined Helm default.

## 1. Cluster permissions (what ArgoCD can do to the Kubernetes API)

Verified with:

```
kubectl get clusterrolebinding,rolebinding -A | grep argocd
kubectl describe clusterrole argocd-application-controller
kubectl describe clusterrole argocd-server
helm get values argocd -n argocd --all
```

Findings:

- `helm get values argocd -n argocd` returns `USER-SUPPLIED VALUES: null` —
  ArgoCD was installed with the chart's stock defaults, no custom
  `--set`/`-f` overrides for RBAC scope.
- `createClusterRoles: true` (chart default) and no `clusterRoleRules`
  overrides were supplied for `controller` or `server`.
- The resulting `argocd-application-controller` ClusterRole grants:
  `resources: "*.*"`, `verbs: ["*"]` (plus non-resource URLs `"*"` / `["*"]`),
  bound cluster-wide via `ClusterRoleBinding/argocd-application-controller`.
- The `argocd-server` ClusterRole grants `"*.*"` for `delete/get/patch`, plus
  scoped rules for `applications.argoproj.io`, `applicationsets.argoproj.io`,
  `pods`, `pods/log`, `events`, and `create` on `jobs.batch` /
  `workflows.argoproj.io`.

**Decision: this is the argo-cd Helm chart's documented default for a
non-namespaced installation**, not something this project introduced or
overlooked. The chart intentionally grants the application-controller
cluster-admin-equivalent access because ArgoCD is designed to potentially
reconcile arbitrary resource types across arbitrary namespaces (and
optionally remote clusters) — restricting it to a fixed resource allowlist
(Deployments/Services/ConfigMaps/Secrets/HPA/Ingress/Jobs) would require
setting `controller.clusterAdminAccess.enabled: false` and hand-writing
`clusterRoleRules` per component, which the chart supports but does not do
by default.

For this project's scope (single cluster, one operator, ArgoCD only manages
the `app`, `database`, and `argocd` namespaces via the `sorcery-app`
Application), the broad default is accepted as-is rather than narrowed,
because:

- Narrowing it would need to be re-verified against every resource kind the
  chart (Bitnami PostgreSQL) and `sorcery-chart` templates emit, and
  would break silently on any future template addition (e.g. a new
  NetworkPolicy or PDB) unless the allowlist is kept in lockstep.
- The blast radius is already bounded by what's deployed in-cluster: nothing
  outside `argocd`/`app`/`database` exists for ArgoCD to touch except
  the ArgoCD installation itself.

**If a reviewer expects namespace/resource-scoped least privilege instead**,
the concrete change would be: set `.controller.clusterAdminAccess.enabled=false`
and `.server.clusterAdminAccess.enabled=false` in the Helm values, then supply
`controller.clusterRoleRules` / `server.clusterRoleRules` limited to
`apps/deployments`, `""/services`, `""/configmaps`, `""/secrets`,
`autoscaling/horizontalpodautoscalers`, `networking.k8s.io/ingresses`,
`batch/jobs`, scoped via `Role`+`RoleBinding` per namespace instead of
`ClusterRole`+`ClusterRoleBinding`. This is a real follow-up, not done here,
because it changes install topology (chart takes on Role/RoleBinding
per-namespace as a manual step, not managed automatically per new namespace).

## 2. ArgoCD access policy (who can log in / act via `argocd-rbac-cm`)

This is a separate control plane: it governs human/API/SSO access to the
ArgoCD server itself (UI, CLI, gRPC), independent of what the underlying
ServiceAccounts can do to the cluster (section 1).

Current `argocd-rbac-cm`:

```yaml
policy.csv: |
  p, role:image-updater, applications, get, */*, allow
  p, role:image-updater, applications, update, */*, allow
  g, image-updater, role:image-updater
policy.default: ""
policy.matchMode: glob
```

- `policy.default: ""` — deny-by-default. Any subject not matched by an
  explicit `p,`/`g,` line gets **no** access. This is the secure default
  (as opposed to setting it to `role:readonly` or `role:admin`, which would
  grant a fallback role to anyone who authenticates).
- The only role currently defined is `role:image-updater` (get/update on
  `applications` across all projects/apps), mapped to the `image-updater`
  local account via the `g,` (group membership) line.
- `argocd-cm` already declares `accounts.image-updater: apiKey` — a local
  API-key-only account exists, tied to that role. **This was pre-staged
  alongside the `ImageUpdater` CR work** (`manifests/image-updater/imageupdater.yaml`,
  ~1h before this audit) even though it's scoped as a later step — flagging
  it here since it's already live, not something to redo.
- Human access today relies entirely on the **built-in `admin` superuser**
  (`admin.enabled: "true"` in `argocd-cm`) — a superuser that bypasses RBAC
  policy entirely. No scoped human/team roles (e.g. `role:developer`,
  `role:readonly`) are defined yet.

**Gap to flag, not yet fixed:** if more than one human/CI identity needs
access, `policy.default: ""` plus zero human-facing roles means everyone
who isn't `admin` gets nothing. That's fine for a single-operator project
but is worth a named follow-up (define a `role:readonly` or similar and map
real users/groups to it) before treating ArgoCD access control as "done"
beyond the single-admin case.

## Summary

| Layer | Status | Action needed |
|---|---|---|
| Cluster permissions (§1) | Chart default, documented above | None — accepted as-is; scoping-down is a known, deferred option |
| ArgoCD access policy (§2) | `policy.default=""` (secure deny-by-default) confirmed; `image-updater` role already pre-configured | None blocking; human RBAC beyond `admin` superuser is a named gap, not addressed here |
