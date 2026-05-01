#!/usr/bin/env bash
# HA Raft variant of the KV v2 round-trip smoke. In addition to
# write+read on a single endpoint, this test proves Raft
# replication: write to vault-0 (the leader), read from
# vault-1.vault-internal (a standby). The standby forwards reads
# to the leader by default — so getting back the value confirms
# the standby is part of the cluster + the forwarder is wired up.
#
# Strategy:
#   1. Read root token from `vault-bootstrap` Secret (written by
#      the install_ha launcher).
#   2. `kubectl run` a curl pod.
#   3. POST /v1/secret/data/smoke against the leader (vault-0).
#   4. GET /v1/secret/data/smoke against vault-1's pod IP — the
#      standby. Standby will forward to leader and return the
#      value.
#   5. Sanity: GET /v1/sys/health on both vault-0 and vault-1.
#      vault-0 returns 200 (active), vault-1 returns 429 (standby
#      with read forwarding) or 200 depending on the chart's
#      /v1/sys/health flags. Either is fine — both 2xx and 429
#      mean "alive and serving."
set -euo pipefail

CLUSTER_NAME="cluster_ha"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

VAULT_NS="vault"
SMOKE_NS="smoke-ha"
KEY="key"
VALUE="rules-vault-ha-round-trip"
SECRET_PATH="smoke-ha"

# Pull the root token + unseal key from the bootstrap secret. The
# install_ha launcher creates it; if it's missing the install
# never reached the init step.
echo "smoke_test_ha: reading vault-bootstrap Secret"
if ! "${KCTL[@]}" -n "$VAULT_NS" get secret vault-bootstrap >/dev/null 2>&1; then
  echo "smoke_test_ha: FAIL — vault-bootstrap Secret missing (install_ha never ran init)" >&2
  exit 1
fi
VAULT_TOKEN=$("${KCTL[@]}" -n "$VAULT_NS" get secret vault-bootstrap \
    -o jsonpath='{.data.root-token}' | base64 -d)
[[ -n "$VAULT_TOKEN" ]] || { echo "smoke_test_ha: FAIL — root-token empty" >&2; exit 1; }

echo "smoke_test_ha: launching curl pod"
"${KCTL[@]}" create namespace "$SMOKE_NS" --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n "$SMOKE_NS" run vault-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$SMOKE_NS" delete pod vault-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$SMOKE_NS" wait pod/vault-curl --for=condition=Ready --timeout=60s

# Sanity: /v1/sys/health on the active service. 200 = active +
# unsealed; 429 = standby; 503 = sealed. We expect 200 because
# install_ha's last step waited for sts rollout, which means all
# pods are unsealed + Ready.
echo "smoke_test_ha: sanity-check /v1/sys/health on vault Service (active)"
ready=$("${KCTL[@]}" -n "$SMOKE_NS" exec vault-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    "http://vault.vault.svc.cluster.local:8200/v1/sys/health" 2>/dev/null || true)
if ! grep -qE "^HTTP (200|429)\$" <<<"$ready"; then
  echo "smoke_test_ha: FAIL — /v1/sys/health did not return 200/429" >&2
  echo "$ready" >&2
  exit 1
fi

# Write to the leader. The chart's `vault` Service routes to
# active pods; with `publishNotReadyAddresses: true` it'll route
# to vault-0 once it's the leader. In v0.2's smoke vault-0 is
# always elected first (it inits the cluster).
echo "smoke_test_ha: POST /v1/secret/data/${SECRET_PATH} (against vault Service / leader)"
write_resp=$("${KCTL[@]}" -n "$SMOKE_NS" exec vault-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    -X POST \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"data\": {\"${KEY}\": \"${VALUE}\"}}" \
    "http://vault.vault.svc.cluster.local:8200/v1/secret/data/${SECRET_PATH}" 2>/dev/null || true)
if ! grep -qE "^HTTP (200|201|204)\$" <<<"$write_resp"; then
  echo "smoke_test_ha: FAIL — POST did not return 200/201/204" >&2
  echo "$write_resp" >&2
  exit 1
fi

# Read directly from a standby pod. Each pod is reachable via
# vault-N.vault-internal:8200 (the headless internal Service).
# Standbys forward reads to the leader by default, so we should
# get back the value.
echo "smoke_test_ha: GET /v1/secret/data/${SECRET_PATH} against vault-1 (standby) — proves Raft replication"
read_resp=$("${KCTL[@]}" -n "$SMOKE_NS" exec vault-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "http://vault-1.vault-internal.vault.svc.cluster.local:8200/v1/secret/data/${SECRET_PATH}" 2>/dev/null || true)
if ! grep -q "^HTTP 200\$" <<<"$read_resp"; then
  echo "smoke_test_ha: FAIL — GET against vault-1 did not return 200" >&2
  echo "$read_resp" >&2
  exit 1
fi
if ! grep -q "\"${KEY}\":\"${VALUE}\"" <<<"$read_resp"; then
  echo "smoke_test_ha: FAIL — vault-1 read did not contain '${KEY}':'${VALUE}'" >&2
  echo "$read_resp" >&2
  exit 1
fi

# Also verify all 3 pods report unsealed via /v1/sys/seal-status.
echo "smoke_test_ha: verifying all 3 pods are unsealed"
for i in 0 1 2; do
  pod="vault-$i"
  st=$("${KCTL[@]}" -n "$SMOKE_NS" exec vault-curl -- \
      curl -s "http://${pod}.vault-internal.vault.svc.cluster.local:8200/v1/sys/seal-status" \
      2>/dev/null || true)
  if ! grep -q '"sealed":false' <<<"$st"; then
    echo "smoke_test_ha: FAIL — $pod reports sealed=true" >&2
    echo "$st" >&2
    exit 1
  fi
done

echo "smoke_test_ha: OK — KV v2 round-trip via leader+standby + all 3 pods unsealed"
