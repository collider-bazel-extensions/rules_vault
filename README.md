# rules_vault

Bazel rules for [HashiCorp Vault](https://www.vaultproject.io/) in tests. Two families:

- **Hermetic server (no cluster)**
  - `vault_server` — a dev-mode `vault` on a free port with a known root token. It waits for `/v1/sys/health`, applies your configuration (secrets engines, auth methods, policies, setup scripts), then writes `$TEST_TMPDIR/<name>.env`. It drops into a rules_itest `itest_service`.
  - `vault_server_health_check` — pairs with `vault_server`.
  - `vault_test` — `sh_test` macro: one test, one server.
  - `vault_policy` — HCL policies, parsed by `vault policy fmt` on every build, so a bad policy fails `bazel build`.
- **Cluster install (kind)**
  - `vault_install` / `vault_health_check` — dev mode: one replica, in-memory, auto-unsealed.
  - `vault_install_ha` / `vault_health_check_ha` — HA Raft: three replicas, scripted init + unseal + raft join.

The server rules need no host `vault`: the binary comes from HashiCorp's release zips, pinned and SHA-256-verified for linux and darwin on amd64 and arm64. They need `python3` on the host.

> **Nothing here is production-safe.** Dev mode keeps everything in memory, unsealed, with a known root token and no TLS. The HA install stores a 1-of-1 Shamir unseal key in a cleartext Secret. These are test fixtures.

---

## Contents

- [Installation](#installation)
- [The vault CLI](#the-vault-cli)
- [Hermetic server](#hermetic-server)
- [Cluster install](#cluster-install)
- [Talking to Vault](#talking-to-vault)
- [Pinned versions](#pinned-versions)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_vault", version = "0.4.0")
git_override(
    module_name = "rules_vault",
    remote = "https://github.com/collider-bazel-extensions/rules_vault",
    commit = "3d346a11eb6b322e77ee3cd1354d0a131b5282dc",  # v0.4.0
)

# rules_vault depends on rules_kubectl, which is not in the BCR either.
bazel_dep(name = "rules_kubectl", version = "0.2.0")
git_override(
    module_name = "rules_kubectl",
    remote = "https://github.com/collider-bazel-extensions/rules_kubectl",
    commit = "81b60ab80df46b64c612f2576ffef0a7af98ccb6",  # v0.2.0
)

# The vault binary for vault_server / vault_test / vault_policy.
vault = use_extension("@rules_vault//:extensions.bzl", "vault")
vault.version(version = "1.21.2")
use_repo(
    vault,
    "vault_1_21_2_darwin_amd64",
    "vault_1_21_2_darwin_arm64",
    "vault_1_21_2_linux_amd64",
    "vault_1_21_2_linux_arm64",
)
```

To pin by archive and integrity instead of a git commit, replace the `git_override` with:

```python
archive_override(
    module_name = "rules_vault",
    urls = ["https://github.com/collider-bazel-extensions/rules_vault/archive/refs/tags/v0.4.0.tar.gz"],
    strip_prefix = "rules_vault-0.4.0",
    integrity = "sha256-F8DQvOuY67hd45MyYafSdRLiDDpRcNEaRptgVypFJwo=",
)
```

The `vault` extension only honours the root module's `version` tags (the `mod.is_root` guard used across this organization), so declare it in your own `MODULE.bazel`. rules_vault registers the toolchains itself. Bzlmod only.

The release archive leaves out `tests/` and `tools/`, which load dev-only modules (rules_itest, rules_kind, rules_helm), so `bazel query @rules_vault//...` works with `archive_override`. A `git_override` checks out the whole repository, `tests/` and `tools/` included, and `@rules_vault//...` then fails to load; name packages instead (`@rules_vault//:all`, `@rules_vault//toolchain:all`).

---

## The vault CLI

`@rules_vault//:vault` runs the toolchain's `vault`, the version you pin with `vault.version(...)`, with whatever arguments you give it:

```sh
bazel run @rules_vault//:vault -- version
bazel run @rules_vault//:vault -- policy fmt ./policies/worker.hcl
VAULT_ADDR=https://vault.example:8200 bazel run @rules_vault//:vault -- kv get secret/app
```

It runs from the directory you ran `bazel run` in, so relative paths in the arguments resolve there. `VAULT_*` variables come from your shell. It is a plain executable, so it also works as `data` for your own targets, where it finds the binary through `RUNFILES_DIR`.

---

## Hermetic server

### `vault_test`

```python
load("@rules_vault//:defs.bzl", "vault_policy", "vault_test")

vault_policy(
    name = "policies",
    srcs = glob(["policies/*.hcl"]),     # worker.hcl → policy "worker"
)

vault_test(
    name = "pki_test",
    srcs = ["pki_test.sh"],
    secrets_engines = {"pki": "pki"},    # mount path → type
    policies = [":policies"],
    setup = [":configure"],              # e.g. an sh_binary around configure.sh
)
```

```sh
# pki_test.sh — VAULT_ADDR / VAULT_TOKEN are set and `vault` is on PATH.
vault kv get -field=api_url secret/app/config
WORKER=$(vault token create -policy=worker -field=token)
VAULT_TOKEN=$WORKER vault write pki/issue/installations common_name=a.example.test
```

`tests/example_test.sh` is a complete example:
- `configure.sh` creates a root CA, a role, a token role and a secret;
- the test reads the KV secret, issues a certificate and signs an intermediate CSR;
- it checks what the worker and renewal-token policies allow and refuse;
- it revokes a token by accessor.

What the test sees:

| Variable | |
|---|---|
| `VAULT_ADDR`, `VAULT_HOST`, `VAULT_PORT` | the server (`http://127.0.0.1:<port>`) |
| `VAULT_TOKEN` | the root token (`root_token`, default `root`) |
| `VAULT` | absolute path to the vault binary, also put on `PATH` |
| `VAULT_AUDIT_LOG` | the file audit log, with `audit = True` |
| anything setup exported | see below |

| `vault_test` / `vault_server` argument | Default | |
|---|---|---|
| `root_token` | `"root"` | dev root token; Vault refuses IDs starting `s.`, `b.`, `r.`, `hvs.`, `hvb.`, `hvr.` |
| `secrets_engines` | `{}` | mount path → engine type, enabled in key order. `secret/` is already KV v2 in dev mode |
| `auth_methods` | `{}` | mount path → auth method type |
| `policies` | `[]` | `vault_policy` targets, each written under its name |
| `setup` | `[]` | scripts run in order after the above |
| `audit` | `False` | enable the file audit device |
| `ready_timeout` | `30` | seconds to wait for `/v1/sys/health` |
| `extra_args` | `[]` | extra `vault server` flags, e.g. `["-log-level=debug"]` |
| `args`, `env`, `data`, `deps`, `size`, `timeout`, `tags`, … | | as for `sh_test` (`vault_test` only) |

**Setup scripts.** Executable targets (an `sh_binary`, …) run directly; plain files run with `bash`. Each gets:
- `VAULT_ADDR`, `VAULT_TOKEN` (root), `VAULT`, and `vault` on `PATH`;
- `VAULT_EXPORT_FILE`: `NAME=VALUE` lines appended there are added to the env file, so the test sees them. Use this to hand over a role ID or a token.

**Failures.** The test fails, naming the cause, if any of these happen:
- Vault exits at start;
- it isn't healthy within `ready_timeout`;
- an engine, auth method or policy can't be applied;
- a setup script fails.

The output includes Vault's log and the failing step's output. In every case the test body never runs.

Each test gets its own server, with its own ports and in-memory storage, so tests are safe under `--jobs=N`. The server is stopped when the test ends.

### `vault_server` + `vault_server_health_check` (rules_itest)

```python
load("@rules_vault//:defs.bzl", "vault_server", "vault_server_health_check")

vault_server(name = "vault", setup = [":configure"], tags = ["manual"])
vault_server_health_check(name = "vault_health", server = ":vault", tags = ["manual"])

itest_service(
    name = "vault_svc",
    exe = ":vault",
    health_check = ":vault_health",
)
```

The server writes `$TEST_TMPDIR/vault.env` (named after the target) once it is healthy *and* configured. A Go or Python test reads it, or takes `VAULT_ADDR` / `VAULT_TOKEN` from a wrapper. The server ignores any `VAULT_*` in its own environment. SIGTERM stops Vault, removes the env file and exits 0.

### `vault_policy`

```python
vault_policy(
    name = "policies",
    srcs = ["worker.hcl", "renewal.hcl"],
    deps = [],                  # other vault_policy targets
    check_format = False,       # True: also require `vault policy fmt` formatting
)
```

`vault policy fmt` runs offline as a validation action. A syntax error or an unknown capability fails any build that includes the policy, and so does an unformatted file when `check_format = True`. Two policies with the same name fail analysis.

---

## Cluster install

Install Vault into a kind cluster for end-to-end tests:

```python
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_vault//:defs.bzl", "vault_install", "vault_health_check")

# 1. Cluster.
kind_cluster(name = "cluster", k8s_version = "1.35")
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

# 2. Vault.
vault_install(name = "vault_install_bin")
vault_health_check(name = "vault_health_bin")
sh_binary(name = "vault_install_wrapper", srcs = ["install_wrapper.sh"], data = [":vault_install_bin"])
sh_binary(name = "vault_health_wrapper",  srcs = ["health_wrapper.sh"],  data = [":vault_health_bin"])

itest_service(
    name = "vault_svc",
    exe = ":vault_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":vault_health_wrapper",
)

# 3. Your test workload — see `tests/` for a KV v2 round-trip.
```

### Macros

#### `vault_install`

```python
vault_install(
    name = "vault_install_bin",
    namespace = "vault",          # default — chart's manifest hard-codes this
    wait_timeout = "300s",        # default
)
```

Expands to a `kubectl_apply(...)` target that:

- Applies `@rules_vault//private/manifests:vault.yaml`.
- `create_namespace = True`.
- `server_side = True`.
- `wait_for_rollouts = ["sts/vault"]`.
- `wait_timeout = "300s"`.

#### `vault_health_check`

Drops into `itest_service.health_check`. Same wait shape with
`--timeout=0s`.

#### `vault_install_ha`

```python
vault_install_ha(
    name = "vault_install_ha_bin",
    namespace = "vault",          # default
)
```

Emits an `sh_binary` running `@rules_vault//private:install_ha.sh`
with the rendered HA Raft manifest as a runfile. The launcher
sequences:

1. `kubectl apply --server-side -f vault-ha.yaml`
2. wait for `vault-0/1/2` to enter Running phase (sealed)
3. `vault operator init -key-shares=1 -key-threshold=1` on
   vault-0
4. write `vault-bootstrap` Secret with `unseal-key` + `root-token`
5. `vault operator unseal` on vault-0 (becomes Raft leader)
6. `vault operator raft join` + unseal on vault-1, vault-2
7. `kubectl rollout status sts/vault` (all 3 pods Ready)
8. idle until SIGTERM

The launcher is **idempotent across restarts** — if vault-0
reports `initialized: true`, it reads the existing Secret and
skips directly to unsealing. Pod restarts re-seal but don't
re-init the underlying raft state.

Drops into `itest_service.exe`. Consumers retrieve the root
token via:

```bash
kubectl -n vault get secret vault-bootstrap \
    -o jsonpath='{.data.root-token}' | base64 -d
```

#### `vault_health_check_ha`

Drops into `itest_service.health_check`. Same `sts/vault` rollout
wait (by the time `vault_install_ha` is idling, all 3 pods are
unsealed + Ready, so the rollout poll passes).

---

## Talking to Vault

Once Vault is up, the in-cluster Service
`vault.<namespace>.svc.cluster.local:8200` accepts HTTP requests.
All authenticated calls take an `X-Vault-Token` header (alternate
to `Authorization: Bearer`).

| Path | Use |
|---|---|
| `GET /v1/sys/health` | Liveness / readiness. 200 unsealed, 503 sealed/standby. |
| `GET /v1/sys/seal-status` | Inspect the seal state. |
| `POST /v1/secret/data/<path>` | Write a KV v2 secret. Body: `{"data": {<key>: <value>}}`. |
| `GET /v1/secret/data/<path>` | Read a KV v2 secret. Response body: `{"data": {"data": {<kv>}, "metadata": {...}}}`. |

> **KV v2 path includes a `/data/` segment** between the mount and
> the secret name (`/v1/secret/data/foo`, NOT `/v1/secret/foo`).
> The `v1/` is the API version prefix; the `data/` is the KV
> engine version's marker. Easy first-CI gotcha.

For complete API docs see [Vault's HTTP API
reference](https://developer.hashicorp.com/vault/api-docs).

---

## Pinned versions

| Component | Version | Source |
|---|---|---|
| vault binary | `1.21.2` | https://releases.hashicorp.com/vault/ (`vault_<ver>_SHA256SUMS`) |
| Helm chart | `vault-0.32.0` (Vault 1.21.2) | https://github.com/hashicorp/vault-helm |

To pin new binaries, run `tools/update_checksums.sh <version>`. It pins the four platforms from HashiCorp's SHA256SUMS and cross-checks each against a download. `--check` verifies the existing pins and changes nothing; CI runs it.

---

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| vault binary (server rules) | Fully hermetic: pinned zip + SHA-256 per platform. | `python3` from the host runs the launcher. |
| Vault manifests (dev + HA) | Fully hermetic. Chart .tgz + sha256 pinned in `tools/versions.bzl`; both variants rendered + committed. | Re-render via `bash tools/render_vault.sh <version> [dev\|ha]`. |
| `kubectl` | Inherited from `rules_kubectl`. | |
| Target cluster | Out of scope. | |
| Vault container image | Pulled at runtime. `docker.io/hashicorp/vault:1.21.2` (overridable via chart `server.image`). | Future: pre-load via `kind_cluster.images`. |
| `curlimages/curl:8.10.1` (smoke) | Pulled at runtime by the smoke pod. | |

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- `tests/` and `tools/` are `export-ignore` in `.gitattributes`: nothing outside them may load or reference them.
- `bazel test //tests/...` runs everything that needs no container
  runtime; the kind smokes (`//tests:smoke_test`,
  `//tests:smoke_test_ha`) are `manual`.
- Bumping the pinned chart version: edit `tools/versions.bzl`,
  add a `helm_template + sh_binary` block in `tools/BUILD.bazel`,
  run `bash tools/render_vault.sh <new-version>`, commit.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted

- macOS validation
- Auto-unseal via [Transit](https://developer.hashicorp.com/vault/docs/configuration/seal/transit)
  (compose: a dev-mode `vault_install` instance acting as the
  Transit seal cluster for an HA Raft `vault_install_ha`
  instance) — eliminates the cleartext-Shamir-key-in-Secret
  pattern v0.2 ships
- Kubernetes auth method smoke (a workload pod authenticates to
  Vault via its ServiceAccount token, reads a secret)
- Vault Agent Injector smoke
- Transit secrets engine smoke (encrypt/decrypt round-trip)
- PKI secrets engine smoke (issue + verify a leaf cert)
- Compose with [`rules_certmanager`](https://github.com/collider-bazel-extensions/rules_certmanager)
  (cert-manager's Vault Issuer talking to this rules_vault install)
