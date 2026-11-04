#!/usr/bin/env bash
# A server that can't start, isn't healthy in time, or whose setup fails
# exits non-zero, names Vault and the cause, shows the log, and leaves no
# env file or vault process; vault_test fails before running the test.
#
# Argv: <bad_flag server> <bad_setup server> <slow server>
#       <trampoline> <failing_vault_test server> <failing_vault_test inner>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

# run <name> <rootpath>: runs it, expecting failure; output in $out.
run() {
  local name="$1" path="$TEST_SRCDIR/_main/$2" rc=0
  out=$(timeout 120 "$path" 2>&1) || rc=$?
  [[ "$rc" != 0 ]] || fail "$name: exited 0. Output: $out"
  [[ "$rc" != 124 ]] || fail "$name: hung. Output: $out"
  [[ ! -f "$TEST_TMPDIR/$name.env" ]] || fail "$name: env file written"
}

# The port vault listened on, from its log; it must be closed now.
assert_stopped() {
  local log="$TEST_TMPDIR/vault-$1/vault.log" port
  port=$(sed -n 's|.*Api Address: http://127.0.0.1:\([0-9]*\).*|\1|p' "$log" | head -1)
  [[ -n "$port" ]] || fail "$1: no Api Address in $log"
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then fail "$1: vault still listening on $port"; fi
}

run bad_flag_server "$1"
grep -q "Vault exited with status" <<<"$out" || fail "bad_flag: cause not named: $out"
grep -q "flag provided but not defined" <<<"$out" || fail "bad_flag: vault log not shown: $out"
echo "ok: vault that can't start"

run bad_setup_server "$2"
grep -q "setup script .*fail_setup.sh failed with status 3" <<<"$out" || fail "bad_setup: step not named: $out"
grep -q "fail_setup: refusing on purpose" <<<"$out" || fail "bad_setup: script output not shown: $out"
grep -q "Vault log:" <<<"$out" || fail "bad_setup: vault log not shown: $out"
assert_stopped bad_setup_server
echo "ok: failing setup script"

run slow_server "$3"
grep -q "Vault was not healthy (GET /v1/sys/health) within 0.001s" <<<"$out" || fail "slow: cause not named: $out"
echo "ok: readiness timeout"

rc=0
out=$(TEST_TMPDIR="$TEST_TMPDIR/inner" ; mkdir -p "$TEST_TMPDIR"; export TEST_TMPDIR
      timeout 120 "$TEST_SRCDIR/_main/$4" "$5" "$6" failing_vault_test_vault 2>&1) || rc=$?
[[ "$rc" != 0 && "$rc" != 124 ]] || fail "failing vault_test: status $rc: $out"
grep -q "vault_test: Vault server exited" <<<"$out" || fail "vault_test: cause not named: $out"
if grep -q "TEST BODY RAN" <<<"$out"; then fail "vault_test ran the test body"; fi
echo "ok: vault_test fails before the test runs"
echo "PASS"
