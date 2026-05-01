"""Maintainer-side: chart .tgz pin.

Vault helm chart .tgz is hosted at
`https://helm.releases.hashicorp.com/vault-<version>.tgz`. The
chart is `apiVersion: v2` so it's `helm template`-able with no
helm-repo config.
"""

VAULT_CHART_VERSIONS = {
    "0.32.0": {
        "chart_url": "https://helm.releases.hashicorp.com/vault-0.32.0.tgz",
        "chart_sha256": "e31ddf3f6dd031c0f5407dd6b63361ea5ff655f89c781049b39f4c2a95a6f88a",
    },
}
