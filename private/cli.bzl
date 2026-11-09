"""vault_cli — the resolved vault binary as a `bazel run` target.

`bazel run @rules_vault//:vault -- <args>` runs the toolchain's vault (the
version pinned with `vault.version(...)`) from the caller's directory, so
relative paths in the arguments resolve where the command was typed.
"""

load("//toolchain:toolchain.bzl", "VAULT_TOOLCHAIN_TYPE")

_WRAPPER = """\
#!/usr/bin/env bash
set -euo pipefail
# vault at the pinned version: found in runfiles, run from the caller's directory.
if [[ -d "$0.runfiles" ]]; then r="$0.runfiles"
elif [[ -n "${{RUNFILES_DIR:-}}" ]]; then r="$RUNFILES_DIR"
else echo "{target}: cannot find runfiles" >&2; exit 1; fi
r="$(cd "$r" && pwd)"
bin="$r/{rlocation}"
if [[ -n "${{BUILD_WORKING_DIRECTORY:-}}" ]]; then cd "$BUILD_WORKING_DIRECTORY"; fi
exec "$bin" "$@"
"""

def _rlocation(ctx, f):
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return ctx.workspace_name + "/" + f.short_path

def _vault_cli_impl(ctx):
    info = ctx.toolchains[VAULT_TOOLCHAIN_TYPE].vault
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        output = out,
        content = _WRAPPER.format(
            target = str(ctx.label),
            rlocation = _rlocation(ctx, info.vault_bin),
        ),
        is_executable = True,
    )
    return [
        info,
        DefaultInfo(
            executable = out,
            files = depset([out]),
            runfiles = ctx.runfiles(files = [info.vault_bin]),
        ),
    ]

vault_cli = rule(
    implementation = _vault_cli_impl,
    executable = True,
    toolchains = [VAULT_TOOLCHAIN_TYPE],
    doc = "Runs the resolved vault binary with the given arguments, from " +
          "$BUILD_WORKING_DIRECTORY under `bazel run`.",
)
