"""vault_policy — Vault ACL policies checked at build time.

`vault policy fmt` parses every file as a validation action, so a syntax
error or an unknown capability fails `bazel build` of anything that
depends on the policy (a vault_server, a vault_test), with no test to
remember to run.

Each policy is named after its file: `worker.hcl` → `worker`.
"""

load(":providers.bzl", "VaultPolicyInfo")

_TOOLCHAIN = "//toolchain:vault"

def policy_name(f):
    """`dir/worker.hcl` → `worker`."""
    name = f.basename
    return name[:-len(".hcl")] if name.endswith(".hcl") else name

def _vault_policy_impl(ctx):
    vault = ctx.toolchains[_TOOLCHAIN].vault.vault_bin
    policies = {}
    for dep in ctx.attr.deps:
        for name, f in dep[VaultPolicyInfo].policies.items():
            if name in policies and policies[name] != f:
                fail("{}: two policies named '{}': {} and {}".format(
                    ctx.label, name, policies[name].path, f.path))
            policies[name] = f
    for f in ctx.files.srcs:
        name = policy_name(f)
        if name in policies and policies[name] != f:
            fail("{}: two policies named '{}': {} and {}".format(
                ctx.label, name, policies[name].path, f.path))
        policies[name] = f

    marker = ctx.actions.declare_file(ctx.label.name + ".checked")
    ctx.actions.run(
        executable = ctx.executable._check,
        arguments = [vault.path, marker.path, "1" if ctx.attr.check_format else "0"] +
                    [f.path for f in ctx.files.srcs],
        inputs = ctx.files.srcs + [vault],
        outputs = [marker],
        mnemonic = "VaultPolicyCheck",
        progress_message = "Checking Vault policies %{label}",
    )
    files = depset(ctx.files.srcs, transitive = [d[DefaultInfo].files for d in ctx.attr.deps])
    return [
        DefaultInfo(files = files),
        VaultPolicyInfo(policies = policies),
        OutputGroupInfo(_validation = depset([marker])),
    ]

vault_policy = rule(
    implementation = _vault_policy_impl,
    doc = "Vault ACL policies (HCL), parsed by `vault policy fmt` on every build.",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".hcl"],
            doc = "Policy files. Each is named after its basename without `.hcl`.",
        ),
        "deps": attr.label_list(
            providers = [VaultPolicyInfo],
            doc = "Other vault_policy targets whose policies are included.",
        ),
        "check_format": attr.bool(
            default = False,
            doc = "Also fail when a file differs from `vault policy fmt` output.",
        ),
        "_check": attr.label(
            default = "//private:check_policy",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [_TOOLCHAIN],
)
