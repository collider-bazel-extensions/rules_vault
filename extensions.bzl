"""Bzlmod extension. Single `version` tag — fetches the HashiCorp Vault
release zip for each supported platform.

(The `vault_chart` extension in //tools is the maintainer-only chart
download for the Kubernetes install manifests.)
"""

load("//private:repositories.bzl", "vault_binary_repo")
load("//private:versions.bzl", "PLATFORMS")

_version_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),  # e.g. "1.21.2"
})

def _impl(mctx):
    # Only honor `version` tags from the root module — same is_root guard
    # as rules_nats / rules_prometheus. Without it, rules_vault's own
    # MODULE.bazel and the consumer would each emit `@vault_<ver>_<plat>`
    # repos and Bazel would collide them.
    for mod in mctx.modules:
        if not mod.is_root:
            continue
        for tag in mod.tags.version:
            for plat in PLATFORMS.keys():
                vault_binary_repo(
                    name = "vault_{}_{}".format(tag.version.replace(".", "_"), plat),
                    version = tag.version,
                    platform = plat,
                )

vault = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
