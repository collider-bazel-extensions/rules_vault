#!/usr/bin/env bash
# Example setup script (vault_server.setup), in the shape of a project's
# configure.sh: a root CA and an installation role on pki/, a token role
# for renewal tokens, and an app secret. Runs with VAULT_ADDR, VAULT_TOKEN
# (root) and `vault` on PATH; exports values to the test through
# $VAULT_EXPORT_FILE.
set -euo pipefail

vault secrets tune -max-lease-ttl=87600h pki >/dev/null
vault write -field=certificate pki/root/generate/internal \
    common_name="rules_vault example root" ttl=87600h > /dev/null
vault write pki/roles/installations \
    allowed_domains=installations.example.test allow_subdomains=true max_ttl=72h >/dev/null

# Renewal tokens: renewal policy only, renewable, orphaned from the worker.
vault write auth/token/roles/renewal \
    allowed_policies=renewal orphan=true renewable=true token_period=1h >/dev/null

vault kv put secret/app/config api_url=https://api.example.test greeting="hello world" >/dev/null

{
  echo "APP_SECRET_PATH=secret/app/config"
  echo "APP_GREETING=hello world"
} >> "$VAULT_EXPORT_FILE"
