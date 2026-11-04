#!/usr/bin/env bash
# The issue #4 acceptance example: vault_test runs configure.sh against a
# hermetic Vault, then the test reads a KV secret, issues and signs PKI
# certificates, and checks what the worker and renewal policies allow.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
ROOT="$VAULT_TOKEN"

# Fails the test unless "$@" is refused with a 403 ("permission denied",
# or for `vault kv` the preflight capability check).
expect_denied() {
  local out
  if out=$("$@" 2>&1); then fail "expected permission denied: $*"; fi
  grep -qE "permission denied|Code: 403" <<<"$out" || fail "expected a 403 from: $*; got: $out"
}

# ---- environment from the server -----------------------------------------
[[ "$(command -v vault)" == "$VAULT" ]] || fail "vault on PATH is $(command -v vault), not $VAULT"
[[ "$VAULT_ADDR" == "http://127.0.0.1:$VAULT_PORT" ]] || fail "VAULT_ADDR=$VAULT_ADDR"
[[ "$APP_GREETING" == "hello world" ]] || fail "setup export APP_GREETING='$APP_GREETING'"

# ---- KV secret written by configure.sh -----------------------------------
[[ "$(vault kv get -field=api_url "$APP_SECRET_PATH")" == "https://api.example.test" ]] \
  || fail "KV secret not readable"
echo "ok: KV secret"

# ---- worker policy --------------------------------------------------------
WORKER=$(vault token create -policy=worker -ttl=1h -field=token)
export VAULT_TOKEN="$WORKER"
[[ "$(vault kv get -field=greeting secret/app/config)" == "hello world" ]] || fail "worker cannot read its config"
expect_denied vault kv put secret/app/config api_url=evil
expect_denied vault kv get secret/other

cert=$(vault write -field=certificate pki/issue/installations \
  common_name=i-123.installations.example.test ttl=1h)
[[ "$cert" == "-----BEGIN CERTIFICATE-----"* ]] || fail "worker could not issue a certificate"
if vault write pki/issue/installations common_name=evil.example.com >/dev/null 2>&1; then
  fail "role issued a certificate outside allowed_domains"
fi
expect_denied vault write pki/root/sign-intermediate csr=x
expect_denied vault token create -policy=worker
echo "ok: worker policy (read config, issue certs, nothing else)"

# The worker mints a renewal token through the token role.
RENEWAL=$(vault token create -role=renewal -field=token)
export VAULT_TOKEN="$RENEWAL"
vault token renew >/dev/null || fail "renewal token cannot renew itself"
expect_denied vault token revoke "$WORKER"
expect_denied vault write pki/issue/installations common_name=r.installations.example.test
expect_denied vault token create -role=renewal
expect_denied vault kv get secret/app/config
echo "ok: renewal token renews and can't revoke, issue or mint"

# ---- revocation by accessor ------------------------------------------------
export VAULT_TOKEN="$ROOT"
accessor=$(vault write -field=accessor auth/token/lookup token="$RENEWAL")
vault token revoke -accessor "$accessor" >/dev/null
if VAULT_TOKEN="$RENEWAL" vault token renew >/dev/null 2>&1; then
  fail "revoked token still renews"
fi
echo "ok: revoked by accessor"

# ---- sign a CSR: an intermediate CA signed by the root -------------------
csr=$(vault write -field=csr pki_int/intermediate/generate/internal common_name="rules_vault example intermediate")
signed=$(vault write -field=certificate pki/root/sign-intermediate csr="$csr" format=pem_bundle ttl=8760h)
# set-signed only accepts a certificate for the key behind the CSR.
vault write pki_int/intermediate/set-signed certificate="$signed" >/dev/null
[[ "$(vault read -field=certificate pki_int/cert/ca)" == "-----BEGIN CERTIFICATE-----"* ]] \
  || fail "intermediate CA not installed"
echo "ok: CSR signed by the root and installed as the intermediate"

echo "PASS"
