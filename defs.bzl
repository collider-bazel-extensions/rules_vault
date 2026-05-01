"""Public API for rules_vault."""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

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
