# Operational read policy for External Secrets Operator's real (non-test)
# secret access. Distinct from eso-test-read (kv/test/* only, reserved for
# throwaway smoke tests) — this is the policy that ClusterSecretStore
# vault-backend actually authenticates as via the eso-role auth role.
#
# Widen this file explicitly, one path at a time, as real secrets migrate
# — mirrors this repo's own precedent for role:jenkins-ci's glob being
# widened deliberately and reviewably rather than granted broad upfront
# (see manifests/argocd/RBAC.md).
#
# Currently covers: pg-credentials (database namespace), git-creds
# (argocd namespace, scoped to the exact secret name, not a
# kv/data/argocd/* glob — widen to a glob only once multiple secrets
# under argocd/ actually justify it).

path "kv/data/database/*" {
  capabilities = ["read"]
}

path "kv/metadata/database/*" {
  capabilities = ["read", "list"]
}

path "kv/data/argocd/git-creds" {
  capabilities = ["read"]
}

path "kv/metadata/argocd/git-creds" {
  capabilities = ["read", "list"]
}
