"""Bzlmod extension. Single `version` tag — fetches the HashiCorp Vault
release zip for each supported platform.

(The `vault_chart` extension in //tools is the maintainer-only chart
download for the Kubernetes install manifests.)
"""

load("//private:repositories.bzl", "vault_binary_repo")
load("//private:versions.bzl", "PLATFORMS", "VAULT_VERSIONS")

_version_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),  # e.g. "1.21.2"
})

def _impl(mctx):
    # Every module's `version` tags, deduplicated. The repos are named by
    # version (`vault_<ver>_<plat>`), so tags from different modules can't
    # collide; the only clash was this extension creating a repo twice.
    # rules_vault's own MODULE.bazel imports vault_1_21_2_* and registers
    # the toolchain for every consumer, so its own tag must always count:
    # through v0.4.0 only the root's tags did, and a root without
    # vault.version() failed to resolve. A consumer's extra version adds
    # repos it can use_repo; the registered toolchain stays rules_vault's.
    versions = {}
    for mod in mctx.modules:
        for tag in mod.tags.version:
            versions[tag.version] = None
    for version in sorted(versions.keys()):
        if version not in VAULT_VERSIONS:
            fail("rules_vault: vault.version(version = \"{}\") is not supported. Supported: {}".format(
                version,
                ", ".join(sorted(VAULT_VERSIONS.keys())),
            ))
        for plat in PLATFORMS.keys():
            vault_binary_repo(
                name = "vault_{}_{}".format(version.replace(".", "_"), plat),
                version = version,
                platform = plat,
            )

vault = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
