#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="cluster"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
INSTALL_BIN="${RUNFILES_DIR}/_main/tests/vault_install_ha_bin"
[[ -x "$INSTALL_BIN" ]] || { echo "wrapper: vault_install_ha_bin not at $INSTALL_BIN" >&2; exit 1; }

env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
deadline=$(( $(date +%s) + 60 ))
while [[ ! -f "$env_file" ]]; do
  if (( $(date +%s) >= deadline )); then
    echo "install_wrapper_ha: kind env file never appeared at $env_file" >&2
    exit 1
  fi
  sleep 1
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

# Diagnostic dump. HA Raft adds Raft-specific failure modes —
# pods up but not joining the cluster, unseal failures, etc.
on_install_fail() {
  local rc=$?
  echo "===== install_wrapper_ha: install_bin exited $rc — dumping cluster state =====" >&2
  echo "---- pods/sts/svc/secrets (-n vault) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n vault get pods,sts,svc,secrets -o wide >&2 || true
  echo "---- describe sts/vault ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n vault describe sts/vault >&2 || true
  for i in 0 1 2; do
    echo "---- vault-$i logs --tail=100 ----" >&2
    "$KUBECTL" --kubeconfig="$KUBECONFIG" -n vault logs "vault-$i" --tail=100 >&2 || true
    echo "---- vault-$i status ----" >&2
    "$KUBECTL" --kubeconfig="$KUBECONFIG" -n vault exec "vault-$i" -- vault status 2>&1 >&2 || true
  done
  exit "$rc"
}
trap on_install_fail ERR

"$INSTALL_BIN"
