# rules_vault

Bazel rules for HashiCorp Vault in tests:
- a hermetic dev-mode server per test (`vault_server`, `vault_test`, `vault_policy`), over a pinned vault binary;
- a Kubernetes install over the pinned hashicorp/vault-helm chart (`vault_install` dev mode, `vault_install_ha` HA Raft).

See DESIGN.md.

## Commit requirements

- All tests must pass before any commit with code changes: `bazel test //tests/...`. Run the kind smokes (`//tests:smoke_test`, `//tests:smoke_test_ha`) too when install code changes.
- All documentation (`README.md`, `DESIGN.md`, `CLAUDE.md`) must be updated to reflect any code changes before committing: new rules, changed attributes, new public API surface, behaviour changes.

## Repo layout

```
rules_vault/
├── .gitattributes            # tests/ + tools/ export-ignore (they load dev-only modules)
├── BUILD.bazel               # //:vault — the pinned CLI (`bazel run`)
├── MODULE.bazel              # module; vault toolchain; dev deps (helm, itest, kind)
├── defs.bzl                  # public API (install macros defined here; server rules re-exported)
├── extensions.bzl            # `vault.version()` → vault_<ver>_<plat> repos (all modules' tags, deduplicated)
├── private/
│   ├── versions.bzl          # VAULT_VERSIONS: url / sha256 per platform
│   ├── repositories.bzl      # per-platform repo: release zip → vault
│   ├── cli.bzl               # vault_cli: toolchain binary → run wrapper (cd $BUILD_WORKING_DIRECTORY)
│   ├── providers.bzl         # VaultBinaryInfo, VaultPolicyInfo
│   ├── policy.bzl            # vault_policy (+ validation action)
│   ├── check_policy.sh       # `vault policy fmt` per file; --check-format diff
│   ├── server.bzl            # vault_server, vault_server_health_check, VaultServerInfo
│   ├── server.sh.tmpl        # runfiles resolution (into variables) → launcher.py
│   ├── health_check.sh.tmpl  # exits 0 iff the env file exists
│   ├── launcher.py           # ports → vault -dev → /v1/sys/health → configure → env file → SIGTERM
│   ├── test.bzl              # vault_test macro
│   ├── vault_test_trampoline.sh  # server → env → test (not exec)
│   ├── install_ha.sh         # HA Raft apply + init + unseal + raft join
│   └── manifests/            # rendered charts (committed; do not hand-edit)
├── toolchain/                # toolchain_type, per-platform toolchains, :current
├── config/                   # chart render values (dev, HA)
├── tools/                    # chart pin + render flow, update_checksums.sh
└── tests/
    ├── BUILD.bazel
    ├── analysis_tests.bzl    # install macro; server/policy providers; bad-attribute failures
    ├── testdata/             # policies (worker, renewal), bad policies, configure.sh, fail_setup.sh
    ├── example_test.sh       # issue #4 acceptance: KV, PKI issue + CSR sign, policies, revoke
    ├── cli_test.sh           # //:vault: pinned version, caller's directory, args forwarded
    ├── default_test.sh       # dev defaults, args + env forwarded
    ├── server_test.sh        # direct run: env file, mounts, audit, extra_args, SIGTERM
    ├── server_failure_test.sh  # bad flag / failing setup / readiness timeout / vault_test
    ├── server_cleanup_test.sh  # vault stopped when a vault_test ends
    ├── itest_test.sh         # vault_server as a rules_itest service
    ├── policy_check_test.sh, health_check_test.sh, checksums_test.sh,
    ├── wrapper_resolve_test.sh  # a missing runfile stops the server wrapper
    └── smoke_test*.sh, *_wrapper*.sh  # kind compositions (manual)
```

## Key concepts

- **Dev mode, known token.** `vault server -dev` is unsealed and in-memory, with KV v2 at `secret/`. The root token is `root_token` (default `root`). IDs starting `s.`, `b.`, `r.`, `hvs.`, `hvb.`, `hvr.` fail analysis, because Vault refuses them.
- **Two ports.** The dev cluster listener is on port+1, so the launcher picks a free pair and retries on a clash.
- **Ready means configured.** Steps run in this order: engines, auth methods, policies, audit (only with `audit`), setup scripts. The env file is written only after all succeed. A failure names the step and prints Vault's log.
- **Exports.** Setup scripts append `NAME=VALUE` to `$VAULT_EXPORT_FILE`. The launcher adds them to the env file, shell-quoted.
- **No leakage.** The server runs without the caller's `VAULT_*`, and with `HOME` in its state dir.
- **Shutdown.** Handlers are installed before Vault starts. Once Vault is ready, the SIGTERM handler only terminates and arms a kill timer. It must not `wait()`, because the main thread holds Popen's wait lock.
- **vault_test.** The trampoline shifts its 3 arguments and runs (doesn't `exec`) the test, so the EXIT trap stops Vault.
- **vault_policy.** `vault policy fmt` is an offline parser, used as a validation action. A policy's name is its basename without `.hcl`.

## Public API

```python
load("@rules_vault//:defs.bzl",
    "vault_policy",                # srcs, deps, check_format
    "vault_server",                # root_token, secrets_engines, auth_methods, policies, setup,
                                   # audit, ready_timeout, extra_args
    "vault_server_health_check",   # server
    "vault_test",                  # srcs + vault_server attrs + args, env, data, deps, ...
    "vault_install", "vault_health_check",          # kind, dev mode
    "vault_install_ha", "vault_health_check_ha",    # kind, HA Raft
    "VaultBinaryInfo", "VaultPolicyInfo", "VaultServerInfo",
)
```

`@rules_vault//:vault` (`private/cli.bzl`) is the pinned CLI: `bazel run @rules_vault//:vault -- <args>` runs from the caller's directory.

The release archive leaves out `tests/` and `tools/` (`.gitattributes` `export-ignore`) because they load dev-only modules; nothing else may reference them. `REPO.bazel` `ignore_directories` is not an option: it hides them from this repo too.

## Development

```sh
bazel test //tests/...                       # hermetic; no container runtime
systemd-run --scope --user --property=Delegate=yes -- \
    bazel test //tests:smoke_test --test_output=streamed     # kind (podman)
tools/update_checksums.sh 1.21.2             # re-pin binaries; --check to verify
bash tools/render_vault.sh 0.32.0 [dev|ha]   # re-render a chart manifest
```

Don't use `pkill -f 'vault server'` to clean up: the pattern matches the shell running it. Use `pgrep -x vault`.

### Test results (last full run: 2026-11-09)

All 20 hermetic test targets pass on Linux x86_64 (Vault 1.21.2). 40 parallel runs of the server tests were clean, and no vault processes were left behind. A bad policy fails `bazel build`, and switching the trampoline back to `exec` fails `server_cleanup_test`, and dropping the wrapper's `cd` or its absolute runfiles path fails `cli_test`; all were were checked by hand.

| Test target | What it verifies | Result |
|---|---|---|
| `//tests:example_test` | configure.sh; KV read; worker issues certs and nothing else; renewal token renews but can't revoke, issue or mint; revoke by accessor; CSR signed by the root | PASSED |
| `//tests:default_test` | dev defaults (KV v2, no audit), `vault` on PATH, args + env forwarded | PASSED |
| `//tests:server_test` | env file keys, root_token, engines + auth, audit log, extra_args, caller VAULT_* ignored, SIGTERM exit 0 | PASSED |
| `//tests:server_failure_test` | bad flag, failing setup (named, vault stopped), readiness timeout, vault_test never runs its body | PASSED |
| `//tests:server_cleanup_test` | vault stopped when a vault_test ends | PASSED |
| `//tests:itest_test` | vault_server + health check as an itest_service | PASSED |
| `//tests:policy_check_test` | good / bad capability / syntax error / check_format | PASSED |
| `//tests:health_check_test` | exits non-zero without env file, 0 with | PASSED |
| `//tests:wrapper_resolve_test` | a missing runfile (vault binary, setup script) stops the server wrapper, naming it, before the launcher runs | PASSED |
| `//tests:cli_test` | `//:vault` runs the pinned version from `RUNFILES_DIR` (also a relative one); relative paths resolve from `BUILD_WORKING_DIRECTORY`; args forwarded | PASSED |
| `//tests:checksums_test` | every pinned URL has a 64-hex SHA-256 | PASSED |
| `//tests:vault_server_analysis` (8), `vault_install_analysis` (1) | providers, health check, duplicate policy, bad / reserved token, bad timeout, bad mount | PASSED |

The kind smokes (`smoke_test`, `smoke_test_ha`) pass under rootless podman (2026-11-08).

## Known limitations

- `python3` is required on the host for the server launcher.
- The hermetic server is dev mode only: no TLS, no persistent storage, no sealed start.
- `vault_test` wraps `sh_test`; other languages use `vault_server` through rules_itest.
- The install namespace is fixed to `vault` by the rendered manifests.
