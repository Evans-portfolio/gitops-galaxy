# Read-only access for Jenkins' own AppRole (authenticated as itself, not
# via Kubernetes auth, since Jenkins runs as a Docker container on the
# host, not in-cluster). Scoped to the whole kv/jenkins/* prefix as a
# glob — a deliberate departure from the exact-path-per-secret discipline
# used for kv/data/argocd/* in eso-read.hcl. That discipline exists
# because argocd/ is a *shared* prefix used by multiple different K8s
# consumers; jenkins/ is dedicated to one consumer (Jenkins' own AppRole),
# so no other identity in this Vault instance would ever plausibly need
# this prefix.

path "kv/data/jenkins/*" {
  capabilities = ["read"]
}

path "kv/metadata/jenkins/*" {
  capabilities = ["read", "list"]
}
