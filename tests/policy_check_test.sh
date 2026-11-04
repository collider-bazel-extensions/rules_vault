#!/usr/bin/env bash
# check_policy.sh (vault_policy's validation action): accepts good
# policies, rejects syntax errors and unknown capabilities, and rejects
# unformatted files only with check_format.
#
# Argv: <check_policy.sh> <vault> <good.hcl> <bad_capability> <bad_syntax> <unformatted>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

r() {
  local c
  for c in "$TEST_SRCDIR/_main/$1" "$TEST_SRCDIR/${1#../}"; do
    [[ -e "$c" ]] && { printf '%s\n' "$c"; return; }
  done
  fail "not in runfiles: $1"
}
CHECK="$(r "$1")"; VAULT="$(r "$2")"
GOOD="$(r "$3")"; BADCAP="$(r "$4")"; BADSYN="$(r "$5")"; UNFMT="$(r "$6")"
m="$TEST_TMPDIR/marker"

check() { rm -f "$m"; "$CHECK" "$VAULT" "$m" "$@"; }

check 0 "$GOOD" || fail "good policy rejected"
[[ -f "$m" ]] || fail "no marker for a good policy"
check 1 "$GOOD" || fail "formatted policy rejected by check_format"

if out=$(check 0 "$BADCAP" 2>&1); then fail "unknown capability accepted"; fi
grep -q 'invalid capability "reed"' <<<"$out" || fail "bad capability not named: $out"
[[ ! -f "$m" ]] || fail "marker written for a bad policy"

if out=$(check 0 "$BADSYN" 2>&1); then fail "syntax error accepted"; fi
grep -q "bad_syntax.hcl: failed to parse policy" <<<"$out" || fail "syntax error not named: $out"

check 0 "$UNFMT" || fail "unformatted but valid policy rejected without check_format"
if out=$(check 1 "$UNFMT" 2>&1); then fail "unformatted policy accepted with check_format"; fi
grep -q "unformatted.hcl is not formatted" <<<"$out" || fail "format failure not named: $out"
echo "PASS"
