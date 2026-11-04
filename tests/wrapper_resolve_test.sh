#!/usr/bin/env bash
# The server wrapper stops, naming the file, when a runfile it needs is
# missing, instead of passing an empty path on to the launcher (a failing
# $(resolve ...) inside an argument list doesn't trip `set -e`).
#
# Runs the real wrapper against a copy of this test's runfiles in which the
# launcher is a stub that records it ran, and one file is deleted.
#
# Argv: <server wrapper> <launcher.py> <runfile to delete>...
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
wrapper_short="$1"; launcher_short="$2"; shift 2

path_in() {  # path_in <runfiles root> <short path>
  case "$2" in ../*) printf '%s/%s\n' "$1" "${2#../}" ;; *) printf '%s/_main/%s\n' "$1" "$2" ;; esac
}

run() {  # run [<short path to delete>]; sets $out, $rc, $ran
  local rf="$TEST_TMPDIR/rf" marker="$TEST_TMPDIR/launcher_ran"
  rm -rf "$rf" "$marker"; mkdir -p "$rf"
  cp -as "$(cd "$TEST_SRCDIR" && pwd -P)/." "$rf/"
  local stub; stub=$(path_in "$rf" "$launcher_short")
  rm -f "$stub"
  printf 'import sys\nopen(%s, "w").write(" ".join(sys.argv[1:]))\n' "'$marker'" > "$stub"
  [[ -z "${1:-}" ]] || rm -f "$(path_in "$rf" "$1")"
  rc=0
  out=$(RUNFILES_DIR="$rf" TEST_TMPDIR="$TEST_TMPDIR/inner" "$(path_in "$rf" "$wrapper_short")" 2>&1) || rc=$?
  ran=""; [[ -f "$marker" ]] && ran=$(cat "$marker")
  return 0
}

mkdir -p "$TEST_TMPDIR/inner"
run
[[ "$rc" == 0 && -n "$ran" ]] || fail "control: the stub launcher didn't run (status $rc): $out"
echo "ok: control run reaches the launcher"

for missing in "$@"; do
  run "$missing"
  [[ "$rc" != 0 ]] || fail "$missing missing: wrapper exited 0"
  grep -qF "not in runfiles: $missing" <<<"$out" || fail "$missing missing: not named: $out"
  [[ -z "$ran" ]] || fail "$missing missing: the launcher still ran with: $ran"
  echo "ok: missing $missing stops the wrapper before the launcher"
done
echo "PASS"
