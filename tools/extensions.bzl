"""Maintainer-only chart fetch — fires only when rules_vault is the root."""

load("//tools:repositories.bzl", "vault_chart_repository")

_version_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),
})

def _impl(mctx):
    for mod in mctx.modules:
        if not mod.is_root:
            continue
        for tag in mod.tags.version:
            vault_chart_repository(
                name = "vault_chart_" + tag.version.replace(".", "_"),
                version = tag.version,
            )

vault_chart = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
