"""Public API for rules_vault."""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# In v0.1's smoke render (Vault chart 0.32.0, dev mode), the chart
# emits one StatefulSet (`vault`, 1 replica, in-memory storage,
# auto-unsealed) + 2 Services (`vault`, `vault-internal`) +
# ServiceAccount + ClusterRoleBinding. No Deployments. No CRDs —
# Vault doesn't ship Kubernetes CRDs in core (the Vault Secrets
# Operator is a separate project).
_VAULT_ROLLOUTS = [
    "sts/vault",
]

def vault_install(
        name,
        namespace = "vault",
        wait_timeout = "300s",
        **kwargs):
    """Apply the pinned Vault manifest into `namespace` and block
    until the Vault StatefulSet is rolled out before idling.

    Drops into `itest_service.exe`. v0.1 renders Vault in **dev
    mode**:

      * single replica, in-memory storage, auto-unsealed at startup
      * predictable root token (`smoke-fixture-root-token-...`,
        hardcoded into the manifest via the chart's
        `server.dev.devRootToken` value)
      * Vault Agent Injector and CSI driver disabled to keep
        footprint small

    **Dev mode is not production-safe.** Production deployments
    pivot to HA Raft (`server.ha.enabled: true` + integrated
    storage), real init/unseal flow (or auto-unseal via cloud KMS /
    Transit), and a real auth method (Kubernetes auth /
    JWT-OIDC / etc.). v0.2 is the candidate for an HA-Raft
    rendered alternative.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_vault//private/manifests:vault.yaml"],
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_deployments = list(extra_deploys),
        wait_for_rollouts = list(_VAULT_ROLLOUTS) + list(extra_rollouts),
        wait_for_crds = list(extra_crds),
        wait_timeout = wait_timeout,
        **kwargs
    )

def vault_health_check(
        name,
        namespace = "vault",
        **kwargs):
    """Readiness probe paired with `vault_install`."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(extra_deploys),
        wait_for_rollouts = list(_VAULT_ROLLOUTS) + list(extra_rollouts),
        wait_for_crds = list(extra_crds),
        **kwargs
    )

def vault_install_ha(
        name,
        namespace = "vault",
        **kwargs):
    """Apply the pinned HA-Raft Vault manifest, then init + unseal +
    raft-join the 3 server pods, then idle.

    Drops into `itest_service.exe`. Different shape from
    `vault_install`: HA Raft pods come up sealed, and Vault's
    readiness probe runs `vault status` (exits 2 on sealed),
    so kubectl_apply's `wait_for_rollouts` would hang. The custom
    launcher (`@rules_vault//private:install_ha.sh`) handles the
    full sequence:

      1. `kubectl apply -f vault-ha.yaml --server-side`
      2. wait for vault-0/1/2 pods to enter Running phase
      3. `vault operator init -key-shares=1 -key-threshold=1`
         on vault-0 (NOT prod-safe — 1-of-1 shamir is no key
         sharing)
      4. write the resulting unseal key + root token to a
         `vault-bootstrap` Secret
      5. `vault operator unseal` on each pod, with raft join on
         vault-1/vault-2 first
      6. `kubectl rollout status sts/vault` (now all 3 Ready)
      7. idle until SIGTERM

    The `vault-bootstrap` Secret is the consumer-facing artifact —
    `kubectl get secret vault-bootstrap -n vault -o jsonpath=...`
    yields the root token + unseal key. Smoke tests authenticate
    via `X-Vault-Token: <root-token>`.

    **Production NOT safe.** Shamir 1-of-1 + a Secret holding the
    unseal key in cleartext defeats the point of the seal. Real
    HA deployments use cloud KMS or Transit auto-unseal, multiple
    operators each holding a Shamir share, and a real auth method
    (Kubernetes / JWT-OIDC / etc.) instead of root-token-from-Secret.
    """
    # The launcher reads $VAULT_NAMESPACE (default "vault"). Consumer
    # wrappers source the kind env file then `export VAULT_NAMESPACE`
    # before exec'ing this binary if they're using a non-default
    # namespace. The chart hardcodes `namespace: vault` in every
    # rendered resource (and in cluster-scoped RoleBindings), so
    # changing the namespace requires re-rendering — passing it
    # through the macro is mostly cosmetic.
    sh_binary(
        name = name,
        srcs = ["@rules_vault//private:install_ha.sh"],
        data = ["@rules_vault//private/manifests:vault-ha.yaml"],
        **kwargs
    )
    _unused_namespace = namespace  # consumed by the launcher's env var

def vault_health_check_ha(
        name,
        namespace = "vault",
        **kwargs):
    """Readiness probe paired with `vault_install_ha`. Waits on the
    same `sts/vault` rollout — by the time the install_ha launcher
    is idling, all 3 pods are unsealed + Ready."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(extra_deploys),
        wait_for_rollouts = list(_VAULT_ROLLOUTS) + list(extra_rollouts),
        wait_for_crds = list(extra_crds),
        **kwargs
    )
