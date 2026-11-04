# rules_vault — design notes

## Two families

- **Cluster install (v0.1–v0.2).** A pinned hashicorp/vault-helm chart, rendered at maintainer time and applied with rules_kubectl. Dev mode is a single in-memory replica; HA Raft is three replicas with a scripted init, unseal and raft join (`private/install_ha.sh`). This is for end-to-end tests where workloads in a cluster talk to Vault.
- **Hermetic server (v0.3, issue #4).** One dev-mode `vault` process per test, with no cluster. Most code that uses Vault needs only a Vault: configure policies and roles, then check what tokens can do. Booting kind for that costs a minute and needs a container runtime. This family follows rules_nats, rules_alertmanager and rules_prometheus: a toolchain, a launcher, a health check and a `*_test` macro.

## Toolchain

HashiCorp ships one `vault` binary per platform, which is both server and CLI, as a release zip. Checksums are the release's `vault_<ver>_SHA256SUMS`. `tools/update_checksums.sh` re-derives them and cross-checks each against a download; CI runs its `--check`. `//tests:checksums_test` fails on any empty or malformed pin.

- **Extension:** the `vault` extension creates `@vault_<ver>_<plat>` repos and is `mod.is_root`-guarded, like the other repos in this organization.
- **Naming:** the `vault_chart` extension in `//tools` is separate. It downloads the Helm chart, at maintainer time only.
- **Tag shape:** the tag is `vault.version(version = ...)`, not the `versions = [...]` list the issue sketched. The toolchain targets name one version's repos, as in rules_prometheus, so a list would suggest a choice the toolchains can't make.

## `vault_server`: dev mode, a known token

The launcher runs:

```
vault server -dev -dev-root-token-id=<token> -dev-listen-address=127.0.0.1:<port> -dev-no-store-token
```

Dev mode is the right fixture for tests: it is unsealed at start, keeps everything in memory, has a root token chosen in advance, and mounts KV v2 at `secret/`. A test starts from a known state in about half a second.

- **Two ports.** Dev mode opens a cluster listener on port+1, so the launcher picks a port P whose neighbour P+1 is also free. If either turns out to be taken, it retries with a new pair, up to 5 times.
- **Readiness** is `GET /v1/sys/health` returning 200, which means initialized, unsealed and active. The timeout (`ready_timeout`, default 30 s) has been configurable from the start, a lesson from rules_temporal #10.
- **Environment.** The server runs without any `VAULT_*` variables from its caller. A consumer's `VAULT_ADDR` or `VAULT_TOKEN` must not leak into it. `HOME` points into the state dir, so Vault's cache stays out of the user's home under `bazel run`.
- **Token checks.** Vault refuses custom token IDs that look like its own tokens (`s.`, `hvs.`, …). The server would fail at start with only "invalid request", so the rule rejects these at analysis time with a clear message.

## Configuration order, and setup scripts

After the server is healthy, the launcher configures it with the vault CLI, in a fixed order:

1. secrets engines;
2. auth methods;
3. policies;
4. the file audit device, only with `audit = True`;
5. setup scripts.

A setup script can therefore rely on everything declared in Starlark already being in place. A project's existing `configure.sh` usually works unchanged: it gets `VAULT_ADDR`, `VAULT_TOKEN` and `vault` on `PATH`, as it would against a real server.

Each step's failure stops Vault and fails the launcher. The message names the step, and the output includes the step's own output and Vault's log. The env file is written only after every step succeeds. So `vault_server_health_check` (the file exists) and `vault_test` mean "configured", not just "listening".

**Exports.** A setup script often creates something the test needs, such as an AppRole role ID or a token. Scripts append `NAME=VALUE` lines to `$VAULT_EXPORT_FILE`, and the launcher adds them to the env file. Values are shell-quoted there, because the trampoline and consumers `source` it.

**Audit off by default.** The file audit device writes every request to disk, which tests rarely need. `audit = True` turns it on and exports `VAULT_AUDIT_LOG`, for tests that assert on what was audited.

## `vault_policy`

`vault policy fmt` parses HCL and validates capabilities without a server. Run as a validation action, it makes a typo like `capabilities = ["reed"]` fail `bazel build`, instead of failing at `vault policy write` inside a test. A policy is named after its file (`worker.hcl` → `worker`), so the HCL in the repo and the name in tests agree. `check_format` makes formatting part of the check too.

## `vault_test`

The macro creates a `vault_server`, an inner `sh_binary` and an `sh_test` whose source is a static trampoline. This follows rules_nats as fixed in its v0.1.1:

- the trampoline removes its own three arguments before the test sees `"$@"`;
- it *runs* the test rather than `exec`ing it, so its EXIT trap stops Vault when the test ends;
- HUP, INT and TERM exit 129, 130 and 143.

`//tests:server_cleanup_test` runs the trampoline outside Bazel's process cleanup and checks that the port is closed afterwards. It fails if the trampoline `exec`s.

If the server exits before it is ready, the trampoline reports its status and refers to the `[vault_server]` lines above it. The test body never runs, which `//tests:server_failure_test` checks.

## Shutdown

The launcher installs its SIGTERM/SIGINT handler before Vault starts, so a signal during start-up or setup still stops Vault. Once Vault is ready, the handler only calls `terminate()` and arms a 10 s kill timer. The main thread is then blocked in `proc.wait()`, which holds Popen's wait lock. Waiting inside the handler would stall for its whole timeout, which rules_alertmanager hit in its first version.

## What this repo does not (yet) do

- **TLS on the hermetic server.** Dev mode serves plain HTTP. A `-dev-tls` option would need the CA exported (`VAULT_CACERT`).
- **Non-dev storage on the hermetic server.** No Raft or file storage, and no sealed start.
- **Enterprise features** such as namespaces, and HCP.
- **Non-shell `vault_test`.** Use `vault_server` + `vault_server_health_check` through rules_itest.
