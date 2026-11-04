#!/usr/bin/env bash
# vault_test's trampoline stops Vault when the test ends: run it to
# completion (in its own session, so nothing else kills its children), then
# check the port it recorded is closed.
#
# Argv: <trampoline> <record_port server> <record_port inner>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

export RECORD_FILE="$TEST_TMPDIR/port"
inner_tmp="$TEST_TMPDIR/inner"; mkdir -p "$inner_tmp"
TEST_TMPDIR="$inner_tmp" setsid "$TEST_SRCDIR/_main/$1" "$2" "$3" record_port_vault \
  || fail "trampoline exited $?"
port=$(cat "$RECORD_FILE")
[[ -n "$port" ]] || fail "no port recorded"
for _ in $(seq 1 50); do
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || { echo "PASS: vault on $port stopped"; exit 0; }
  sleep 0.1
done
fail "vault still listening on $port after the test ended"
