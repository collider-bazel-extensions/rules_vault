#!/usr/bin/env bash
# vault_server run directly (as rules_itest would): env file, configured
# mounts, audit device, extra_args, caller VAULT_* ignored, SIGTERM.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

SERVER="$TEST_SRCDIR/_main/$1"
env_file="$TEST_TMPDIR/test_server.env"
rm -f "$env_file"

# A consumer's VAULT_ADDR / VAULT_TOKEN must not reach the server.
VAULT_ADDR=http://127.0.0.1:1 VAULT_TOKEN=wrong "$SERVER" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 300); do [[ -f "$env_file" ]] && break; sleep 0.1; done
[[ -f "$env_file" ]] || fail "env file not written"

set -a; source "$env_file"; set +a
for k in VAULT_ADDR VAULT_TOKEN VAULT_HOST VAULT_PORT VAULT VAULT_AUDIT_LOG; do
  [[ -n "${!k:-}" ]] || fail "$k missing from env file"
done
[[ "$VAULT_TOKEN" == "test-token" ]] || fail "root_token: $VAULT_TOKEN"
[[ "$VAULT_HOST" == 127.0.0.1 ]] || fail "VAULT_HOST=$VAULT_HOST"

"$VAULT" secrets list | grep -q '^transit/ *transit' || fail "transit engine not enabled"
"$VAULT" auth list | grep -q '^approle/ *approle' || fail "approle auth not enabled"
"$VAULT" write -f transit/keys/k >/dev/null
[[ -s "$VAULT_AUDIT_LOG" ]] || fail "audit log empty: $VAULT_AUDIT_LOG"
grep -q 'transit/keys/k' "$VAULT_AUDIT_LOG" || fail "request not audited"
grep -q '\[DEBUG\]' "$TEST_TMPDIR/vault-test_server/vault.log" || fail "extra_args -log-level=debug not applied"
echo "ok: configured server"

kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
trap - EXIT
[[ "$rc" == 0 ]] || fail "SIGTERM exit status $rc"
[[ ! -f "$env_file" ]] || fail "env file left after SIGTERM"
if (exec 3<>"/dev/tcp/127.0.0.1/$VAULT_PORT") 2>/dev/null; then fail "vault still listening"; fi
echo "ok: SIGTERM stops vault, exit 0, env file removed"
echo "PASS"
