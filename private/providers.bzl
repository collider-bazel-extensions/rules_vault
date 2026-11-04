"""Providers exposed by rules_vault."""

VaultBinaryInfo = provider(
    doc = "Vault toolchain binary (server and CLI are one executable).",
    fields = {
        "version":   "string — pinned Vault version",
        "vault_bin": "File — the vault executable",
    },
)

VaultPolicyInfo = provider(
    doc = "Checked Vault ACL policies (vault_policy).",
    fields = {
        "policies": "dict string→File — policy name (file basename without " +
                    "`.hcl`) → HCL file; each parsed by `vault policy fmt`",
    },
)
