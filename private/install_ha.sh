#!/usr/bin/env bash
# Custom install launcher for Vault HA Raft mode.
#
# Vault's readiness probe runs `vault status` and exits 2 on
# sealed pods, so a freshly-applied HA Raft manifest's pods sit
# in NotReady forever — `kubectl_apply`'s `wait_for_rollouts`
# would hang. This launcher does the full sequence inline:
#
#   1. apply manifest (server-side)
#   2. wait for vault-0/1/2 pods to enter Running phase (sealed,
#      not Ready)
#   3. `vault operator init` on vault-0 (shamir 1-of-1 — adequate
#      for the smoke fixture, NOT prod-safe)
#   4. unseal vault-0 with the resulting key
#   5. wait for vault-0 Ready (it becomes the Raft leader)
#   6. for vault-1 and vault-2: `vault operator raft join` against
#      vault-0's cluster_addr, then unseal
#   7. wait for sts/vault rollout (now all 3 pods Ready)
#   8. write `vault-bootstrap` Secret (root-token + unseal-key) so
#      the smoke / consumers can authenticate
#   9. idle until SIGTERM (matches kubectl_apply's contract for
#      itest_service.exe).
#
# Idempotency: if step 3's init reports "Vault is already
# initialized" we re-read the key + token from the existing
# vault-bootstrap Secret and skip directly to unsealing. (Pod
# restarts re-seal but don't re-initialize the underlying raft
# state.)
set -euo pipefail

NS="${VAULT_NAMESPACE:-vault}"

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "install_ha: KUBECONFIG not set" >&2
  exit 2
fi
KUBECTL_BIN="${KUBECTL:-kubectl}"
K=("$KUBECTL_BIN" --kubeconfig=$KUBECONFIG)

# Locate the manifest. Bazel runfiles layout puts it at one of
# these paths depending on consumer wiring.
if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
fi
MANIFEST=""
for cand in \
  "${RUNFILES_DIR:-}/_main/private/manifests/vault-ha.yaml" \
  "${RUNFILES_DIR:-}/rules_vault/private/manifests/vault-ha.yaml" \
  "private/manifests/vault-ha.yaml"; do
  [[ -f "$cand" ]] && { MANIFEST="$cand"; break; }
done
[[ -n "$MANIFEST" ]] || { echo "install_ha: vault-ha.yaml not in runfiles" >&2; exit 2; }

trap 'echo "install_ha: SIGTERM, exiting" >&2; exit 143' SIGTERM SIGINT

# ---- 1. apply manifest ------------------------------------------------------
echo "install_ha: creating namespace + applying manifest"
"${K[@]}" create namespace "$NS" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" -n "$NS" apply --server-side --validate=false -f "$MANIFEST"

# ---- 2. wait for pods to be Running ----------------------------------------
echo "install_ha: waiting for vault-0/1/2 to reach Running phase (sealed)..."
for i in 0 1 2; do
  pod="vault-$i"
  deadline=$(( $(date +%s) + 240 ))
  phase=""
  while (( $(date +%s) < deadline )); do
    phase=$("${K[@]}" -n "$NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "$phase" == "Running" ]] && break
    sleep 2
  done
  [[ "$phase" == "Running" ]] || { echo "install_ha: $pod never reached Running (last phase=$phase)" >&2; exit 1; }
done

# ---- 3. init (or recover credentials if already initialized) ----------------
init_status=$("${K[@]}" -n "$NS" exec vault-0 -- vault status -format=json 2>/dev/null || true)
already_initialized="false"
if [[ -n "$init_status" ]]; then
  if grep -q '"initialized": *true' <<<"$init_status"; then
    already_initialized="true"
  fi
fi

if [[ "$already_initialized" == "true" ]]; then
  echo "install_ha: vault-0 already initialized; reading vault-bootstrap Secret"
  if ! "${K[@]}" -n "$NS" get secret vault-bootstrap >/dev/null 2>&1; then
    echo "install_ha: initialized but vault-bootstrap Secret missing — can't recover unseal key" >&2
    exit 1
  fi
  unseal_key=$("${K[@]}" -n "$NS" get secret vault-bootstrap \
      -o jsonpath='{.data.unseal-key}' | base64 -d)
  root_token=$("${K[@]}" -n "$NS" get secret vault-bootstrap \
      -o jsonpath='{.data.root-token}' | base64 -d)
else
  echo "install_ha: initializing vault-0 (shamir 1-of-1)..."
  init_json=$("${K[@]}" -n "$NS" exec vault-0 -- vault operator init \
      -key-shares=1 -key-threshold=1 -format=json)
  unseal_key=$(python3 -c \
      'import json,sys; print(json.load(sys.stdin)["unseal_keys_b64"][0])' \
      <<<"$init_json")
  root_token=$(python3 -c \
      'import json,sys; print(json.load(sys.stdin)["root_token"])' \
      <<<"$init_json")

  # Persist immediately so a partial-unseal failure can recover.
  "${K[@]}" -n "$NS" create secret generic vault-bootstrap \
      --from-literal=unseal-key="$unseal_key" \
      --from-literal=root-token="$root_token" >/dev/null
  echo "install_ha: wrote vault-bootstrap Secret (unseal-key, root-token)"
fi

# ---- 4. unseal vault-0 ------------------------------------------------------
echo "install_ha: unsealing vault-0..."
"${K[@]}" -n "$NS" exec vault-0 -- vault operator unseal "$unseal_key" >/dev/null

# ---- 5. wait for vault-0 Ready (Raft leader) -------------------------------
"${K[@]}" -n "$NS" wait pod/vault-0 --for=condition=Ready --timeout=180s

# ---- 6. raft join + unseal vault-1/vault-2 ---------------------------------
for i in 1 2; do
  pod="vault-$i"
  echo "install_ha: $pod — raft join + unseal..."
  # `raft join` returns 1 if the node is already a member (e.g.
  # restart). Treat as non-fatal — unseal is the actual gate.
  "${K[@]}" -n "$NS" exec "$pod" -- vault operator raft join \
      "http://vault-0.vault-internal:8200" >/dev/null 2>&1 || true
  "${K[@]}" -n "$NS" exec "$pod" -- vault operator unseal "$unseal_key" >/dev/null
done

# ---- 7. wait for sts rollout ------------------------------------------------
"${K[@]}" -n "$NS" rollout status sts/vault --timeout=240s

# ---- 8. enable KV v2 secrets engine at `secret/` ----------------------------
# Dev mode (`vault server -dev`) auto-mounts KV v2 at `secret/`.
# HA Raft (`vault server -config=...`) starts with NO secrets
# engines mounted — `secret/data/foo` returns 404 "no handler for
# route" until an operator runs `vault secrets enable kv-v2`.
# Mount it so the same KV v2 paths work in both modes.
echo "install_ha: enabling KV v2 at secret/"
mounts=$("${K[@]}" -n "$NS" exec vault-0 -- env VAULT_TOKEN="$root_token" \
    vault secrets list -format=json 2>/dev/null || echo '{}')
if ! grep -q '"secret/"' <<<"$mounts"; then
  "${K[@]}" -n "$NS" exec vault-0 -- env VAULT_TOKEN="$root_token" \
      vault secrets enable -path=secret kv-v2
fi

echo "install_ha: Vault HA Raft cluster ready (3 nodes, sealed=false, KV v2 mounted at secret/). Idling until SIGTERM."
while true; do sleep 3600; done
