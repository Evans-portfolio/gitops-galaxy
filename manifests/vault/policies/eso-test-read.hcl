# Read-only access to the throwaway kv/test/* path used to prove the
# External Secrets Operator -> Vault round trip. Deliberately scoped
# narrow (not kv/*) per the jenkins-ci tight-scoping precedent in
# manifests/argocd/RBAC.md — widen explicitly (a new policy, or an
# extended path list here) when real secrets migrate into Vault.

path "kv/data/test/*" {
  capabilities = ["read"]
}

path "kv/metadata/test/*" {
  capabilities = ["read", "list"]
}
