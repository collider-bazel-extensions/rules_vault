#!/usr/bin/env bash
# Maintainer-time script: pin the Vault release zips in
# private/versions.bzl from the release's published SHA256SUMS.
#
#   tools/update_checksums.sh <version>   # add / re-pin <version>
#   tools/update_checksums.sh --check     # verify every pinned entry
#
# Every published sum is cross-checked by downloading the zip and hashing
# it; any mismatch aborts without touching versions.bzl.
set -euo pipefail

cd "$(dirname "$0")/.."
for tool in curl sha256sum python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "update_checksums: needs $tool" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -r -f -- "$work"' EXIT

plats=(linux_amd64 linux_arm64 darwin_amd64 darwin_arm64)

# Prints "<platform> <url> <sha256>" for each platform of <version>,
# verified against the downloaded zip.
published() {
    local ver="$1" plat asset url sum actual base="https://releases.hashicorp.com/vault/$1"
    curl -fsSL -o "$work/sums" "$base/vault_${ver}_SHA256SUMS"
    for plat in "${plats[@]}"; do
        asset="vault_${ver}_${plat}.zip"
        url="$base/$asset"
        sum=$(awk -v a="$asset" '$2 == a {print $1}' "$work/sums")
        [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "update_checksums: no sum for $asset" >&2; exit 1; }
        curl -fsSL -o "$work/zip" "$url"
        actual=$(sha256sum "$work/zip" | awk '{print $1}')
        [[ "$actual" == "$sum" ]] || { echo "update_checksums: $asset hashes to $actual, published $sum" >&2; exit 1; }
        echo "$plat $url $sum"
    done
}

if [[ "${1:-}" == "--check" ]]; then
    status=0
    for ver in $(python3 -I -c '
import re, sys
print(" ".join(sorted(set(re.findall(r"^    \"([0-9][^\"]*)\": \{", open(sys.argv[1]).read(), re.M)))))
' private/versions.bzl); do
        while read -r plat url sum; do
            if grep -qF "\"sha256\": \"$sum\"" private/versions.bzl; then
                echo "OK    $ver $plat"
            else
                echo "DRIFT $ver $plat: published $sum" >&2; status=1
            fi
        done < <(published "$ver")
    done
    exit "$status"
fi

ver="${1:?usage: tools/update_checksums.sh <version> | --check}"
published "$ver" > "$work/pins"
python3 -I - private/versions.bzl "$ver" "$work/pins" <<'PY'
import re, sys
path, ver, pins = sys.argv[1:]
rows = [l.split() for l in open(pins) if l.strip()]
entry = f'    "{ver}": {{\n'
for plat, url, sha in rows:
    entry += (f'        "{plat}": {{\n'
              f'            "url": "{url}",\n'
              f'            "sha256": "{sha}",\n'
              f'        }},\n')
entry += "    },\n"
text = open(path).read()
pat = re.compile(r'    "' + re.escape(ver) + r'": \{\n.*?\n    \},\n', re.S)
if pat.search(text):
    text = pat.sub(lambda m: entry, text)
else:
    text = text.replace("VAULT_VERSIONS = {\n", "VAULT_VERSIONS = {\n" + entry, 1)
open(path, "w").write(text)
print(f"pinned {ver} for {len(rows)} platforms in {path}")
PY
