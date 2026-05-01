#!/usr/bin/env bash
# KV v2 secrets engine round-trip through Vault's HTTP API.
# Strategy:
#
#   1. `kubectl run` a curl pod inside the cluster.
#   2. POST /v1/secret/data/smoke with `{"data": {"key": "value"}}`,
#      authenticated via the dev-mode root token in an
#      `X-Vault-Token` header. KV v2's data-write path includes a
#      `/data/` segment between the mount and the secret name —
#      `/v1/secret/data/<path>`, NOT `/v1/secret/<path>`. v1 mounts
#      use the bare path; the dev-mode default mount is v2.
#   3. GET /v1/secret/data/smoke and assert `data.data.key == "value"`.
#      The double-`data` is KV v2's response shape: outer `data`
#      wraps the version envelope, inner `data` is the actual KV.
#
# Proves: HTTP listener + token auth + KV v2 secrets engine + the
# in-memory backend's read/write path end-to-end. Dev mode means
# everything is auto-unsealed, so we don't need to handle the
# init/unseal flow here — that's a v0.2 (HA Raft) concern.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="smoke"
VAULT_HOST="vault.vault.svc.cluster.local"
# Dev-mode root token — wired in via `server.dev.devRootToken` in
# config/vault-values.yaml. Production replaces with a Secret-mounted
# env var + a real auth method.
VAULT_TOKEN="smoke-fixture-root-token-do-not-use-in-prod-12345"
KEY="key"
VALUE="rules-vault-round-trip"
SECRET_PATH="smoke"

echo "smoke_test: launching curl pod"
"${KCTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n "$NS" run vault-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod vault-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/vault-curl --for=condition=Ready --timeout=60s

# Sanity: /v1/sys/health on dev-mode unsealed Vault returns 200.
# Sealed standbys return 503 by design — dev mode auto-unseals so
# this should be a clean 200 first try. If this fails the install
# wait gating on `sts/vault` rolled out something that didn't
# actually finish booting.
echo "smoke_test: sanity-check Vault /v1/sys/health"
ready=$("${KCTL[@]}" -n "$NS" exec vault-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    "http://${VAULT_HOST}:8200/v1/sys/health" 2>/dev/null || true)
if ! grep -q "^HTTP 200\$" <<<"$ready"; then
  echo "smoke_test: FAIL — /v1/sys/health did not return 200" >&2
  echo "$ready" >&2
  exit 1
fi

# Write a KV v2 secret. Body shape for KV v2 is `{"data": <kv-map>}`.
echo "smoke_test: POST /v1/secret/data/${SECRET_PATH}"
write_resp=$("${KCTL[@]}" -n "$NS" exec vault-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    -X POST \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"data\": {\"${KEY}\": \"${VALUE}\"}}" \
    "http://${VAULT_HOST}:8200/v1/secret/data/${SECRET_PATH}" 2>/dev/null || true)
# 200 (existing path overwrite) or 201/204 (initial create) all
# count as "wrote successfully" per Vault's API.
if ! grep -qE "^HTTP (200|201|204)\$" <<<"$write_resp"; then
  echo "smoke_test: FAIL — POST did not return 200/201/204" >&2
  echo "$write_resp" >&2
  exit 1
fi

# Read it back. KV v2 response shape:
#   {
#     "data": {
#       "data":     {"<key>": "<value>"},   <-- the actual KV
#       "metadata": {...}
#     },
#     ...
#   }
# So the read assertion looks for `"key":"<expected>"` in the body.
echo "smoke_test: GET /v1/secret/data/${SECRET_PATH}"
read_resp=$("${KCTL[@]}" -n "$NS" exec vault-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "http://${VAULT_HOST}:8200/v1/secret/data/${SECRET_PATH}" 2>/dev/null || true)
if ! grep -q "^HTTP 200\$" <<<"$read_resp"; then
  echo "smoke_test: FAIL — GET did not return 200" >&2
  echo "$read_resp" >&2
  exit 1
fi
if ! grep -q "\"${KEY}\":\"${VALUE}\"" <<<"$read_resp"; then
  echo "smoke_test: FAIL — secret body did not contain '${KEY}':'${VALUE}'" >&2
  echo "$read_resp" >&2
  exit 1
fi

echo "smoke_test: OK — KV v2 round-trip succeeded (${KEY}=${VALUE} written + read back via HTTP API)"
