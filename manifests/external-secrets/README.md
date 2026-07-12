# External Secrets Operator — Vault round-trip smoke test

`manifests/external-secrets/clustersecretstore.yaml` wires ESO to Vault
(see `manifests/vault/ESO-INTEGRATION.md` for the Vault-side config), but
no `ExternalSecret` is committed here permanently. Unlike
`manifests/vault/vault-status-test-job.yaml` (a Job that completes once
and can sit `Completed` indefinitely), an `ExternalSecret` is continuously
reconciled — a permanently-committed one pointing at deleted test data
would sit in a perpetual `SecretSyncedError` state every time this
directory is applied. Instead, here's the exact reproducible sequence to
re-run the smoke test on demand:

```bash
# 1. Write throwaway test data into Vault (requires the root token or a
#    sufficiently privileged Vault identity — not something ESO's own
#    scoped eso-test-role can do, since it's read-only)
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=<root-token> \
  vault kv put kv/test/hello foo=bar

# 2. Apply a throwaway ExternalSecret
kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: eso-roundtrip-test
  namespace: external-secrets
spec:
  refreshInterval: 15s
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: eso-roundtrip-test-secret
  data:
    - secretKey: foo
      remoteRef:
        key: test/hello
        property: foo
EOF

# 3. Confirm materialization
kubectl wait --for=condition=Ready externalsecret/eso-roundtrip-test \
  -n external-secrets --timeout=30s
kubectl get secret eso-roundtrip-test-secret -n external-secrets \
  -o jsonpath='{.data.foo}' | base64 -d
# expect: bar

# 4. Clean up fully
kubectl delete externalsecret eso-roundtrip-test -n external-secrets
kubectl delete secret eso-roundtrip-test-secret -n external-secrets
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=<root-token> \
  vault kv metadata delete kv/test/hello
```

Last run live: 2026-07-12 — `foo` decoded to `bar` as expected, then fully
torn down (see `NOTES.md`).
