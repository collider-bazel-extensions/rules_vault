#!/usr/bin/env bash
# Inner test for server_cleanup_test: records where vault listened.
set -euo pipefail
echo "$VAULT_PORT" > "$RECORD_FILE"
