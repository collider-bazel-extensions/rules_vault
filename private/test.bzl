"""vault_test — sh_test macro with an auto-launched dev-mode Vault.

Each target gets its own vault_server (own ports, own in-memory storage),
so tests are safe under `--jobs=N`.

The trampoline (vault_test_trampoline.sh) starts the server, waits for
its env file, sources it (VAULT_ADDR, VAULT_TOKEN, VAULT_HOST,
VAULT_PORT, VAULT, plus setup exports), puts `vault` on PATH and runs the
test with the target's args. It runs the test rather than exec'ing it, so
it can stop the server when the test ends.
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load(":server.bzl", "vault_server")

def vault_test(
        name,
        srcs,
        root_token = "root",
        secrets_engines = None,
        auth_methods = None,
        policies = None,
        setup = None,
        audit = False,
        ready_timeout = 30,
        extra_args = None,
        deps = None,
        data = None,
        args = None,
        size = "medium",
        timeout = None,
        tags = None,
        **kwargs):
    """sh_test against an auto-launched dev-mode Vault.

    Args:
      name: target name.
      srcs: the test script (one file).
      root_token: the dev root token (VAULT_TOKEN).
      secrets_engines: mount path → engine type, e.g. {"pki": "pki"}.
      auth_methods: mount path → auth method type.
      policies: vault_policy targets, written under their names.
      setup: scripts run against the server before the test (see
        vault_server.setup).
      audit: enable the file audit device (VAULT_AUDIT_LOG).
      ready_timeout: seconds to wait for /v1/sys/health.
      extra_args: extra `vault server` flags.
      deps: forwarded to the inner sh_binary.
      data: forwarded to the inner sh_binary.
      args: arguments for the test script.
      size: sh_test size. Default "medium".
      timeout: sh_test timeout.
      tags: tags for the sh_test (helper targets also get "manual").
      **kwargs: forwarded to sh_test (env, env_inherit, flaky, ...).
    """
    tags = tags or []
    server_name = name + "_vault"
    vault_server(
        name = server_name,
        root_token = root_token,
        secrets_engines = secrets_engines or {},
        auth_methods = auth_methods or {},
        policies = policies or [],
        setup = setup or [],
        audit = audit,
        ready_timeout = str(ready_timeout),
        extra_args = extra_args or [],
        tags = tags + ["manual"],
        testonly = True,
    )

    inner_name = name + "_inner"
    sh_binary(
        name = inner_name,
        srcs = srcs,
        deps = deps,
        data = data,
        tags = tags + ["manual"],
        testonly = True,
    )

    sh_test(
        name = name,
        srcs = [Label("//private:vault_test_trampoline.sh")],
        args = [
            "$(rootpath :{})".format(server_name),
            "$(rootpath :{})".format(inner_name),
            server_name,
        ] + (args or []),
        data = [":" + server_name, ":" + inner_name],
        size = size,
        timeout = timeout,
        tags = tags,
        **kwargs
    )
