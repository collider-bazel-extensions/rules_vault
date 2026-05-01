#!/usr/bin/env bash
# Maintainer flow:
#   1. Edit tools/versions.bzl::VAULT_CHART_VERSIONS.
#   2. Add a `helm_template` + `sh_binary` block in tools/BUILD.bazel.
#   3. bash tools/render_vault.sh <chart-version>
set -euo pipefail

VERSION="${1:?usage: tools/render_vault.sh <chart-version> [dev|ha]}"
VARIANT="${2:-dev}"
case "$VARIANT" in
  dev) TARGET="//tools:render_writeback_$(echo "$VERSION" | tr '.' '_')" ;;
  ha)  TARGET="//tools:render_writeback_ha_$(echo "$VERSION" | tr '.' '_')" ;;
  *) echo "render_vault: unknown variant '$VARIANT' (want dev|ha)" >&2; exit 1 ;;
esac

echo "[render_vault] $TARGET"
exec bazel run "$TARGET"
