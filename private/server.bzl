"""vault_server + vault_server_health_check — hermetic Vault test fixtures.

`vault_server` is a long-running executable (see launcher.py) that starts
`vault server -dev` on a free 127.0.0.1 port with a known root token,
waits for GET /v1/sys/health, applies its configuration (secrets engines,
auth methods, policies, optional audit device, setup scripts), then
writes `$TEST_TMPDIR/<name>.env`:

    VAULT_ADDR=http://127.0.0.1:<port>
    VAULT_TOKEN=<root token>
    VAULT_HOST / VAULT_PORT
    VAULT=/abs/path/to/vault
    VAULT_AUDIT_LOG=<path>      # audit = True only
    <NAME=VALUE lines setup scripts appended to $VAULT_EXPORT_FILE>

and runs until SIGTERM. `vault_server_health_check` exits 0 iff that
file exists; it drops into `itest_service.health_check`.

(`vault_health_check` is the Kubernetes install's probe, paired with
`vault_install`.)
"""

load(":providers.bzl", "VaultPolicyInfo")

_TOOLCHAIN = "//toolchain:vault"

VaultServerInfo = provider(
    doc = "A vault_server target.",
    fields = {
        "binary":     "VaultBinaryInfo: the toolchain's binary.",
        "root_token": "string: the dev root token.",
    },
)

# Vault refuses custom token IDs that look like its own tokens.
_RESERVED_TOKEN_PREFIXES = ["s.", "b.", "r.", "hvs.", "hvb.", "hvr."]

_IDENT_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./"

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def check_timeout(label, value):
    """Validate a timeout attribute: a positive number of seconds."""
    raw = value.strip()
    digits = raw.replace(".", "", 1)
    if not raw or not digits.isdigit() or not digits.replace("0", ""):
        fail("{}: ready_timeout = {}: expected a positive number of seconds.".format(
            label, repr(value)))
    return raw

def _check_mounts(label, attr, mounts):
    for path, typ in mounts.items():
        for s in (path, typ):
            if not s or [c for c in s.elems() if c not in _IDENT_CHARS]:
                fail("{}: {} entry {} = {}: paths and types are letters, digits, '_', '-', '.', '/'.".format(
                    label, attr, repr(path), repr(typ)))

def _resolved(flag, p, prefix = ""):
    # One wrapper line: resolve into a variable first (a failing $(resolve)
    # inside an argument list would not stop the script under `set -e`),
    # then append `flag <prefix><path>` to the opts array.
    return "p=\"$(resolve {})\"; opts+=({} {}\"$p\")".format(
        _shell_quote(p), flag, _shell_quote(prefix) if prefix else "")

def _vault_server_impl(ctx):
    vt = ctx.toolchains[_TOOLCHAIN].vault
    token = ctx.attr.root_token
    if not token or [c for c in token.elems() if c not in _IDENT_CHARS]:
        fail("{}: root_token = {}: use letters, digits, '_', '-', '.', '/'.".format(
            ctx.label, repr(token)))
    for prefix in _RESERVED_TOKEN_PREFIXES:
        if token.startswith(prefix):
            fail("{}: root_token = {}: Vault refuses custom token IDs starting with {}".format(
                ctx.label, repr(token), ", ".join(_RESERVED_TOKEN_PREFIXES)))
    _check_mounts(ctx.label, "secrets_engines", ctx.attr.secrets_engines)
    _check_mounts(ctx.label, "auth_methods", ctx.attr.auth_methods)

    config_args = []
    for path, typ in ctx.attr.secrets_engines.items():
        config_args.append("opts+=(--secrets-engine {})".format(_shell_quote(path.strip("/") + "=" + typ)))
    for path, typ in ctx.attr.auth_methods.items():
        config_args.append("opts+=(--auth-method {})".format(_shell_quote(path.strip("/") + "=" + typ)))

    policy_files = []
    seen = {}
    for t in ctx.attr.policies:
        for name, f in t[VaultPolicyInfo].policies.items():
            if name in seen and seen[name] != f:
                fail("{}: two policies named '{}': {} and {}".format(
                    ctx.label, name, seen[name].path, f.path))
            seen[name] = f
    for name in sorted(seen.keys()):
        f = seen[name]
        policy_files.append(f)
        config_args.append(_resolved("--policy", f.short_path, name + "="))

    setup_runfiles = []
    setup_files = []
    for t in ctx.attr.setup:
        exe = t[DefaultInfo].files_to_run.executable
        if exe:
            setup_files.append(exe)
            setup_runfiles.append(t[DefaultInfo].default_runfiles)
            config_args.append(_resolved("--setup", exe.short_path))
        else:
            for f in t[DefaultInfo].files.to_list():
                setup_files.append(f)
                config_args.append(_resolved("--setup", f.short_path))
    if ctx.attr.audit:
        config_args.append("opts+=(--audit)")

    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {
            "__NAME__":          ctx.label.name,
            "__LAUNCHER__":      ctx.file._launcher.short_path,
            "__VAULT__":         vt.vault_bin.short_path,
            "__READY_TIMEOUT__": check_timeout(ctx.label, ctx.attr.ready_timeout),
            "__ROOT_TOKEN__":    token,
            "__CONFIG_ARGS__":   "\n".join(config_args),
            "__EXTRA_ARGS__":    " ".join([_shell_quote(a) for a in ctx.attr.extra_args]),
        },
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [wrapper, ctx.file._launcher, vt.vault_bin] + policy_files + setup_files,
    ).merge_all(setup_runfiles)
    return [
        DefaultInfo(executable = wrapper, runfiles = runfiles),
        VaultServerInfo(binary = vt, root_token = token),
    ]

vault_server = rule(
    implementation = _vault_server_impl,
    executable = True,
    doc = """\
Long-running dev-mode Vault for tests and rules_itest compositions.
Writes `$TEST_TMPDIR/<name>.env` once /v1/sys/health answers 200 and the
configuration has been applied. If Vault doesn't start, isn't healthy
within `ready_timeout`, or a setup step fails, it exits non-zero, naming
the cause and printing Vault's log.

Dev mode: in-memory storage, unsealed, KV v2 mounted at `secret/`, no
TLS, no audit device unless `audit = True`.
""",
    attrs = {
        "root_token": attr.string(
            default = "root",
            doc = "The dev root token, exported as VAULT_TOKEN.",
        ),
        "secrets_engines": attr.string_dict(
            doc = "Mount path → engine type, enabled in key order, e.g. " +
                  "{\"pki\": \"pki\", \"transit\": \"transit\"}. " +
                  "(`secret/` is already KV v2 in dev mode.)",
        ),
        "auth_methods": attr.string_dict(
            doc = "Mount path → auth method type, e.g. {\"approle\": \"approle\"}.",
        ),
        "policies": attr.label_list(
            providers = [VaultPolicyInfo],
            doc = "vault_policy targets; each policy is written under its name.",
        ),
        "setup": attr.label_list(
            allow_files = True,
            doc = "Scripts run in order once the above is applied: executable " +
                  "targets (sh_binary, ...) run directly, plain files with " +
                  "bash. They get VAULT_ADDR, VAULT_TOKEN, VAULT, `vault` on " +
                  "PATH, and VAULT_EXPORT_FILE (NAME=VALUE lines appended " +
                  "there reach the env file).",
        ),
        "audit": attr.bool(
            default = False,
            doc = "Enable the file audit device; its path is VAULT_AUDIT_LOG.",
        ),
        "ready_timeout": attr.string(
            default = "30",
            doc = "Seconds to wait for /v1/sys/health. A positive number.",
        ),
        "extra_args": attr.string_list(
            doc = "Extra `vault server` flags, e.g. [\"-log-level=debug\"].",
        ),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
        "_tmpl": attr.label(default = "//private:server.sh.tmpl", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN],
)

# ---- vault_server_health_check ----------------------------------------------

def _vault_server_health_check_impl(ctx):
    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {"__ENV_FILE_NAME__": ctx.attr.server.label.name + ".env"},
        is_executable = True,
    )
    return [DefaultInfo(executable = wrapper)]

vault_server_health_check = rule(
    implementation = _vault_server_health_check_impl,
    executable = True,
    attrs = {
        "server": attr.label(
            mandatory = True,
            providers = [VaultServerInfo],
            doc = "The vault_server this check pairs with.",
        ),
        "_tmpl": attr.label(default = "//private:health_check.sh.tmpl", allow_single_file = True),
    },
)
