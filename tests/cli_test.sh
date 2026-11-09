#!/usr/bin/env bash
# //:vault (#7): the pinned vault CLI as a runnable target. Runs it the way
# a data dependency does (RUNFILES_DIR) and checks the version and that
# relative paths resolve from BUILD_WORKING_DIRECTORY.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

cli="$PWD/$1"
want="$2"
[[ -x "$cli" ]] || fail "not executable: $cli"

out="$(cd / && "$cli" version)"
[[ "$out" == "Vault v$want "* ]] || fail "version: $out (want v$want)"

# Relative paths resolve from the caller's directory (`bazel run` sets
# BUILD_WORKING_DIRECTORY), not from the runfiles tree.
caller="$TEST_TMPDIR/caller"
mkdir -p "$caller"
printf 'path "secret/*" {capabilities=["read"]}\n' > "$caller/p.hcl"
BUILD_WORKING_DIRECTORY="$caller" "$cli" policy fmt p.hcl >/dev/null \
    || fail "policy fmt p.hcl from BUILD_WORKING_DIRECTORY"
grep -q 'capabilities = \["read"\]' "$caller/p.hcl" || fail "p.hcl not formatted: $(cat "$caller/p.hcl")"

# A relative RUNFILES_DIR still works after the cd.
rel="$(realpath --relative-to="$PWD" "$RUNFILES_DIR")"
[[ "$rel" != /* ]] || fail "could not make RUNFILES_DIR relative"
RUNFILES_DIR="$rel" BUILD_WORKING_DIRECTORY="$caller" "$cli" policy fmt p.hcl >/dev/null \
    || fail "relative RUNFILES_DIR broke after the cd"

# Arguments are forwarded unchanged.
BUILD_WORKING_DIRECTORY="$caller" "$cli" policy fmt "no such.hcl" 2>"$TEST_TMPDIR/err" \
    && fail "missing file accepted"
grep -q "no such.hcl" "$TEST_TMPDIR/err" || fail "argument not forwarded: $(cat "$TEST_TMPDIR/err")"
echo "PASS"
