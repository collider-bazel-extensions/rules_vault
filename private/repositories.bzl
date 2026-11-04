"""Per-platform Vault repo: downloads the release zip at the pinned sha
and exposes the `vault` binary as a filegroup.
"""

load(":versions.bzl", "VAULT_VERSIONS")

_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "vault_bin",
    srcs = ["vault"],
)
"""

def _impl(rctx):
    version = rctx.attr.version
    platform = rctx.attr.platform

    if version not in VAULT_VERSIONS:
        fail("rules_vault: unknown Vault version '{}'. Known: {}".format(
            version, sorted(VAULT_VERSIONS.keys()),
        ))
    pin = VAULT_VERSIONS[version].get(platform)
    if not pin:
        fail("rules_vault: platform '{}' missing for version {}".format(platform, version))

    rctx.download_and_extract(
        url = pin["url"],
        sha256 = pin["sha256"],
        type = "zip",
    )
    rctx.file("WORKSPACE", "workspace(name = \"{}\")\n".format(rctx.name))
    rctx.file("BUILD.bazel", _BUILD)

vault_binary_repo = repository_rule(
    implementation = _impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
    },
)
