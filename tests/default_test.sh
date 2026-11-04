#!/usr/bin/env bash
# vault_test with no configuration: dev-mode defaults, args forwarded.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ $# -eq 2 && "$1" == "one" && "$2" == "two words" ]] || fail "args: $# [$*]"
[[ "$VAULT_TOKEN" == "root" ]] || fail "VAULT_TOKEN=$VAULT_TOKEN"
[[ -x "$VAULT" ]] || fail "VAULT=$VAULT"
[[ "${FROM_ENV_ATTR:-}" == "yes" ]] || fail "env attribute not passed"
vault status >/dev/null || fail "vault status"
[[ "$(vault read -field=options sys/mounts/secret)" == *"version:2"* ]] || fail "secret/ is not KV v2"
[[ "$(vault audit list 2>&1)" == *"No audit devices"* ]] || fail "audit device enabled by default"
[[ -z "${VAULT_AUDIT_LOG:-}" ]] || fail "VAULT_AUDIT_LOG set without audit"
vault kv put secret/x a=1 >/dev/null
[[ "$(vault kv get -field=a secret/x)" == 1 ]] || fail "KV round trip"
echo "PASS"
