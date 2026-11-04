"""vault_toolchain — exposes the platform-resolved `vault` binary as a
`ToolchainInfo`, so rules resolve it via
`ctx.toolchains["@rules_vault//toolchain:vault"]`.

`current_vault_toolchain` forwards the resolved binary as a plain target
(files + runfiles) for `data = [...]` use in tests.
"""

load("//private:providers.bzl", "VaultBinaryInfo")

VAULT_TOOLCHAIN_TYPE = Label("//toolchain:vault")

def _toolchain_impl(ctx):
    info = VaultBinaryInfo(
        version   = ctx.attr.version,
        vault_bin = ctx.file.vault_bin,
    )
    return [
        platform_common.ToolchainInfo(vault = info),
        DefaultInfo(
            files = depset([ctx.file.vault_bin]),
            runfiles = ctx.runfiles(files = [ctx.file.vault_bin]),
        ),
    ]

vault_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "version":   attr.string(mandatory = True),
        "vault_bin": attr.label(allow_single_file = True, mandatory = True),
    },
)

def _current_impl(ctx):
    info = ctx.toolchains[VAULT_TOOLCHAIN_TYPE].vault
    return [
        info,
        DefaultInfo(
            files = depset([info.vault_bin]),
            runfiles = ctx.runfiles(files = [info.vault_bin]),
        ),
    ]

current_vault_toolchain = rule(
    implementation = _current_impl,
    toolchains = [VAULT_TOOLCHAIN_TYPE],
    doc = "The resolved vault binary, as files and runfiles.",
)
