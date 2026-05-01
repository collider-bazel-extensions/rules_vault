# rules_vault

Hermetic [HashiCorp Vault](https://www.vaultproject.io/) install
for Bazel test compositions. Pure glue layer over
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl) —
`vault_install` is a macro emitting a `kubectl_apply` target
pre-configured with Vault's pinned manifest and the right wait
shape (single `sts/vault` StatefulSet rollout).

```python
load("@rules_vault//:defs.bzl", "vault_install", "vault_health_check")

vault_install(name = "vault_install_bin")          # default ns: vault
vault_health_check(name = "vault_health_bin")
```

That's the whole API. Vault is a secrets-management server — it
exposes an HTTP API for reading / writing secrets, dynamic secret
issuance, encryption-as-a-service, PKI, and Kubernetes /
JWT-OIDC / userpass auth methods. v0.1's smoke writes a KV v2
secret, reads it back, asserts the value matches.

**Pinned versions:** Vault helm chart `0.32.0` (Vault `1.21.2`).
The values file is exported as
`@rules_vault//config:vault-values.yaml` for inspection / extension.

> **DEV MODE — NOT PRODUCTION-SAFE.** v0.1's render uses the
> chart's `server.dev.enabled: true`:
>
> - Single replica, in-memory storage. Every restart loses all
>   secrets.
> - Auto-unsealed at startup. No real init/unseal flow.
> - Hardcoded root token in the rendered manifest:
>   `smoke-fixture-root-token-do-not-use-in-prod-12345`.
> - Vault Agent Injector and CSI provider disabled.
>
> v0.2 is the candidate for an HA-Raft alternative (3 replicas,
> integrated storage, real init/unseal flow, auto-unseal via
> cloud KMS or Transit). Most consumers will fork the values for
> their production deployment regardless.

**Supported platforms (v0.1):** any platform where rules_kubectl
runs. Validated on Linux x86\_64 in CI.

---

## Contents

- [Installation](#installation) (Bzlmod-only)
- [Quickstart](#quickstart)
- [Macros](#macros)
- [Talking to Vault](#talking-to-vault)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_vault", version = "0.1.0")
```

Bzlmod-only. Transitively pulls in
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl)
≥ 0.2.0.

---

## Quickstart

```python
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_vault//:defs.bzl", "vault_install", "vault_health_check")

# 1. Cluster.
kind_cluster(name = "cluster", k8s_version = "1.32")
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

---

## Macros

### `vault_install`

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

### `vault_health_check`

Drops into `itest_service.health_check`. Same wait shape with
`--timeout=0s`.

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

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| Vault manifest | Fully hermetic. Chart .tgz + sha256 pinned in `tools/versions.bzl`; rendered + committed. | Re-render via `bash tools/render_vault.sh <version>`. |
| `kubectl` | Inherited from `rules_kubectl`. | |
| Target cluster | Out of scope. | |
| Vault container image | Pulled at runtime. `docker.io/hashicorp/vault:1.21.2` (overridable via chart `server.image`). | Future: pre-load via `kind_cluster.images`. |
| `curlimages/curl:8.10.1` (smoke) | Pulled at runtime by the smoke pod. | |

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- Bumping the pinned chart version: edit `tools/versions.bzl`,
  add a `helm_template + sh_binary` block in `tools/BUILD.bazel`,
  run `bash tools/render_vault.sh <new-version>`, commit.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted

- macOS validation
- HA Raft mode (v0.2 candidate — 3-replica StatefulSet,
  integrated storage, real init/unseal flow, auto-unseal via
  cloud KMS / Transit)
- Kubernetes auth method smoke (a workload pod authenticates to
  Vault via its ServiceAccount token, reads a secret)
- Vault Agent Injector smoke
- Transit secrets engine smoke (encrypt/decrypt round-trip)
- PKI secrets engine smoke (issue + verify a leaf cert)
- Compose with [`rules_certmanager`](https://github.com/collider-bazel-extensions/rules_certmanager)
  (cert-manager's Vault Issuer talking to this rules_vault install)
