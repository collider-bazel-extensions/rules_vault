#!/usr/bin/env bash
# Consumer checks against the commit's release archive (git archive honours
# .gitattributes export-ignore, as GitHub's tag tarballs do):
#   1. no vault.version() in the root resolves, and @rules_vault//:vault
#      runs rules_vault's pinned version
#   2. the same version set twice in the root resolves
#   3. an unsupported version fails, naming vault.version
#   4. @rules_vault//... loads (tests/ and tools/ are not shipped)
# Usage: .github/consumer/check.sh <scratch dir>
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
src="$work/rules_vault"
rm -rf "$work"; mkdir -p "$src"
git -C "$repo" archive HEAD | tar -x -C "$src"
for d in tests tools; do
    if [[ -e "$src/$d" ]]; then echo "FAIL: archive contains $d/" >&2; exit 1; fi
done
pinned="$(sed -n 's/^vault.version(version = "\(.*\)")$/\1/p' "$src/MODULE.bazel")"
kubectl_commit="$(grep -A3 'module_name = "rules_kubectl"' "$src/MODULE.bazel" | sed -n 's/.*commit = "\([0-9a-f]*\)".*/\1/p')"

consumer() { # <name> <extra MODULE.bazel lines>
    local c="$work/$1"
    mkdir -p "$c"
    touch "$c/BUILD.bazel"
    if [[ -f "$repo/.bazelversion" ]]; then cp "$repo/.bazelversion" "$c/"; fi
    cat > "$c/MODULE.bazel" <<MOD
module(name = "consumer")
bazel_dep(name = "rules_vault")
local_path_override(module_name = "rules_vault", path = "$src")
bazel_dep(name = "rules_kubectl", version = "0.2.0")
git_override(
    module_name = "rules_kubectl",
    remote = "https://github.com/collider-bazel-extensions/rules_kubectl",
    commit = "$kubectl_commit",
)
$2
MOD
    echo "$c"
}

# 1. No vault.version(): resolves; the registered toolchain's vault runs.
c="$(consumer untagged "")"
(cd "$c" && bazel mod deps >/dev/null)
(cd "$c" && bazel run @rules_vault//:vault -- version) | tee "$work/untagged.out"
grep -q "^Vault v$pinned " "$work/untagged.out" || { echo "FAIL: untagged consumer did not get vault $pinned" >&2; exit 1; }
echo "PASS: untagged root resolves, vault $pinned"

# 2. The same version twice in the root.
c="$(consumer twice "vault = use_extension(\"@rules_vault//:extensions.bzl\", \"vault\")
vault.version(version = \"$pinned\")
vault.version(version = \"$pinned\")")"
(cd "$c" && bazel mod deps >/dev/null)
echo "PASS: repeated identical vault.version resolves"

# 3. An unsupported version fails with a message naming vault.version.
c="$(consumer unsupported 'vault = use_extension("@rules_vault//:extensions.bzl", "vault")
vault.version(version = "0.0.1")')"
if (cd "$c" && bazel mod deps) > "$work/unsupported.out" 2>&1; then
    echo "FAIL: unsupported version resolved" >&2; exit 1
fi
grep -q 'vault.version(version = "0.0.1") is not supported' "$work/unsupported.out" || {
    cat "$work/unsupported.out" >&2; echo "FAIL: unsupported version: wrong error" >&2; exit 1; }
echo "PASS: unsupported version fails clearly"

# 4. //... loads.
(cd "$work/untagged" && bazel query @rules_vault//... >/dev/null)
echo "PASS: @rules_vault//... loads"
