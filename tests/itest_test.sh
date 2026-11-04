#!/usr/bin/env bash
# The test half of a rules_itest service_test: vault_server ran as an
# itest_service and its health check passed, so its env file is there.
set -euo pipefail
set -a; source "$TEST_TMPDIR/itest_server.env"; set +a
"$VAULT" kv put secret/itest k=v >/dev/null
[[ "$("$VAULT" kv get -field=k secret/itest)" == v ]] || { echo "FAIL: KV round trip" >&2; exit 1; }
"$VAULT" secrets list | grep -q '^transit/' || { echo "FAIL: transit not enabled" >&2; exit 1; }
echo "PASS"
