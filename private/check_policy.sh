#!/usr/bin/env bash
# vault_policy validation action: parse each HCL policy with
# `vault policy fmt` (offline; rejects syntax errors and unknown
# capabilities). With --check-format, also fail when a file is not in
# `vault policy fmt`'s canonical form.
#
#   check_policy.sh <vault> <marker> <check_format 0|1> <policy.hcl>...
set -euo pipefail

vault="$1"; marker="$2"; check_format="$3"; shift 3
case "$vault" in /*) ;; *) vault="$PWD/$vault" ;; esac

work=$(mktemp -d)
trap 'rm -r -f -- "$work"' EXIT
export HOME="$work"   # vault may write a cache dir under $HOME

status=0
for src in "$@"; do
    copy="$work/$(basename "$src")"
    cp "$src" "$copy"
    chmod u+w "$copy"  # generated inputs are read-only
    if ! out=$("$vault" policy fmt "$copy" 2>&1); then
        echo "vault_policy: $src: $out" >&2
        status=1
        continue
    fi
    if [[ "$check_format" == 1 ]] && ! cmp -s "$src" "$copy"; then
        echo "vault_policy: $src is not formatted (vault policy fmt):" >&2
        diff -u "$src" "$copy" >&2 || true
        status=1
    fi
done
[[ "$status" == 0 ]] || exit 1
: > "$marker"
