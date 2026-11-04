"""Analysis-time tests: the install macro, and vault_server / vault_policy
(providers, health check, and the analysis errors for bad attributes)."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@rules_vault//:defs.bzl",
    "VaultPolicyInfo",
    "VaultServerInfo",
    "vault_install",
    "vault_server",
    "vault_server_health_check",
)

def _has_executable_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(
        env,
        target[DefaultInfo].files_to_run.executable != None,
        "expected target to expose an executable",
    )
    return analysistest.end(env)

_has_executable_test = analysistest.make(_has_executable_impl)

def vault_install_test_suite(name):
    vault_install(
        name = name + "_subject",
        tags = ["manual"],
    )
    _has_executable_test(name = name + "_executable", target_under_test = ":" + name + "_subject")
    native.test_suite(name = name, tests = [":" + name + "_executable"])

# ---- hermetic server ---------------------------------------------------------

def _server_info_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, VaultServerInfo in target, "expected VaultServerInfo")
    info = target[VaultServerInfo]
    asserts.equals(env, "analysis-token", info.root_token)
    asserts.equals(env, "1.21.2", info.binary.version)
    asserts.true(env, target[DefaultInfo].files_to_run.executable != None, "expected an executable")
    return analysistest.end(env)

_server_info_test = analysistest.make(_server_info_impl)

def _policy_info_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, ["renewal", "worker"], sorted(target[VaultPolicyInfo].policies.keys()))
    return analysistest.end(env)

_policy_info_test = analysistest.make(_policy_info_impl)

def _fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_fails_test = analysistest.make(
    _fails_impl,
    expect_failure = True,
    attrs = {"message": attr.string()},
)

def vault_server_test_suite(name):
    vault_server(
        name = name + "_server",
        root_token = "analysis-token",
        policies = ["//tests/testdata:policies"],
        tags = ["manual"],
    )
    vault_server_health_check(
        name = name + "_health",
        server = ":" + name + "_server",
        tags = ["manual"],
    )
    vault_server(
        name = name + "_dup_policies",
        policies = ["//tests/testdata:policies", "//tests/testdata:dup_worker"],
        tags = ["manual"],
    )
    vault_server(
        name = name + "_bad_token",
        root_token = "has space",
        tags = ["manual"],
    )
    vault_server(
        name = name + "_reserved_token",
        root_token = "hvs.mine",
        tags = ["manual"],
    )
    vault_server(
        name = name + "_bad_timeout",
        ready_timeout = "soon",
        tags = ["manual"],
    )
    vault_server(
        name = name + "_bad_mount",
        secrets_engines = {"pki": "pki; rm"},
        tags = ["manual"],
    )

    _server_info_test(name = name + "_info", target_under_test = ":" + name + "_server")
    _has_executable_test(name = name + "_health_executable", target_under_test = ":" + name + "_health")
    _policy_info_test(name = name + "_policy_info", target_under_test = "//tests/testdata:policies")
    _fails_test(name = name + "_dup", target_under_test = ":" + name + "_dup_policies",
                message = "two policies named 'worker'")
    _fails_test(name = name + "_token", target_under_test = ":" + name + "_bad_token",
                message = "root_token")
    _fails_test(name = name + "_reserved", target_under_test = ":" + name + "_reserved_token",
                message = "refuses custom token IDs starting with")
    _fails_test(name = name + "_timeout", target_under_test = ":" + name + "_bad_timeout",
                message = "expected a positive number of seconds")
    _fails_test(name = name + "_mount", target_under_test = ":" + name + "_bad_mount",
                message = "secrets_engines entry")
    native.test_suite(name = name, tests = [
        ":" + name + s
        for s in ["_info", "_health_executable", "_policy_info", "_dup", "_token", "_reserved", "_timeout", "_mount"]
    ])
