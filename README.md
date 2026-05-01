# rules_vault

Hermetic [HashiCorp Vault](https://www.vaultproject.io/) install
for Bazel test compositions. Two install modes:

- **Dev mode** (`vault_install`) — single replica, in-memory,
  auto-unsealed, hardcoded root token. ~30s to ready. The
  obvious starting point for anything not actually testing
  Vault's HA / persistence semantics.
- **HA Raft** (`vault_install_ha`) — 3 replicas with integrated
  storage, real init + unseal flow scripted by a custom
  launcher, raft-joined. ~90s to ready. Production-shaped, but
  the unseal key is a 1-of-1 Shamir share stored in a
  cluster-side Secret — still NOT prod-safe.

```python
load("@rules_vault//:defs.bzl",
     "vault_install", "vault_health_check",
     "vault_install_ha", "vault_health_check_ha")

# Dev mode — kubectl_apply target.
vault_install(name = "vault_install_bin")
vault_health_check(name = "vault_health_bin")

# HA Raft — sh_binary launcher (apply + init + unseal + raft join + idle).
vault_install_ha(name = "vault_install_ha_bin")
vault_health_check_ha(name = "vault_health_ha_bin")
```

Vault is a secrets-management server — it exposes an HTTP API
for reading / writing secrets, dynamic secret issuance,
encryption-as-a-service, PKI, and Kubernetes / JWT-OIDC /
userpass auth methods. The smoke writes a KV v2 secret, reads it
back, asserts the value matches (HA smoke also reads from a
standby, proving Raft replication).

**Pinned versions:** Vault helm chart `0.32.0` (Vault `1.21.2`).
Values files exported as
`@rules_vault//config:vault-values.yaml` (dev) and
`@rules_vault//config:vault-ha-values.yaml` (HA Raft).

> **NEITHER MODE IS PRODUCTION-SAFE.**
>
> Dev mode: in-memory storage, auto-unsealed, hardcoded root
> token in the manifest. Every restart loses all secrets.
>
> HA Raft mode: real persistence + real cluster, but `vault
> operator init -key-shares=1 -key-threshold=1` produces a
> single Shamir share that the launcher stores in a
> `vault-bootstrap` Secret in cleartext. That defeats the point
> of the seal. Real production deploys use cloud KMS or Transit
> auto-unseal, multiple operator-held Shamir shares, and a real
> auth method (Kubernetes / JWT-OIDC / etc.) instead of root
> token from a Secret.
>
> Both modes exist for **smoke fixtures**, not production.

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

### `vault_install_ha`

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

### `vault_health_check_ha`

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

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| Vault manifests (dev + HA) | Fully hermetic. Chart .tgz + sha256 pinned in `tools/versions.bzl`; both variants rendered + committed. | Re-render via `bash tools/render_vault.sh <version> [dev\|ha]`. |
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
