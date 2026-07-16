# Network policies — zero-trust, airgapped-by-default

This is the cluster's network security model, in two ideas:

1. **The void** (`manifests/airgap-baseline.yaml`) — every application namespace is
   default-deny. A pod may talk to nothing except: its own namespace, cluster DNS,
   the Kubernetes API, ingress from Traefik, and scrape from monitoring. No outbound
   internet. That's the airgap.
2. **The holes** (`manifests/allowlists.yaml`) — every exception is listed here, one
   block per reason, with a comment saying *why*. If it's not in this file, it's
   blocked. To audit "what can leave this cluster," read this one file.

Enforced by Cilium (`policyEnforcementMode: default`). Observed by Hubble. The console
"recently blocked → allow next time" feature appends new entries to `allowlists.yaml`
through this same GitOps path, so every allow is reviewed in git and revertible.

## Onboarding a namespace (developer how-to)

1. Copy `_TEMPLATE.yaml`, replace `__NAMESPACE__`, drop it in `manifests/`.
   That namespace is now an airgapped void.
2. If the app needs something external, add a clearly-commented block to
   `manifests/allowlists.yaml` (prefer `toFQDNs` by name over CIDR).
3. Watch Hubble (or the console firewall page) for `DROPPED` flows and allow the
   legitimate ones the same way.

## What is NOT here (on purpose)

- **Secrets are never committed.** The Talos admin config and the platform-owner
  service-account token live in OpenBao (`secret/platform/talosconfig`,
  `secret/platform/claude-platform-owner`), not git.
- **Infra namespaces** (`longhorn-system`, `dns-system`, `registry`) are not yet
  airgapped — staged in `pending/infra-airgap.yaml`. Apply them deliberately while
  watching storage/DNS/image-pull; a wrong rule there is cluster-wide.
- **The WordPress updates/plugins-only lockdown** is staged in
  `pending/wordpress-lockdown.yaml` (verify per-site pod labels and Authentik SSO
  egress before applying).

## Reverting

Delete the relevant block from git and let ArgoCD prune it, or
`kubectl delete ciliumnetworkpolicy <name> -n <ns>`. To drop a namespace out of the
void entirely, remove its baseline block.

## Talos note

The dataplane is Cilium, set in Talos machine config (`cluster.network.cni.name: none`)
— see `../cilium/` and `docs/CILIUM-HUBBLE-MIGRATION-RUNBOOK.md`. A future
`tofu apply` must keep `cni.name: none` or it will try to reinstall flannel.
