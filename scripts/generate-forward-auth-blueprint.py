#!/usr/bin/env python3
"""
generate-forward-auth-blueprint.py — DYNAMIC forward-auth provisioning.

Scans every Traefik IngressRoute manifest, finds hosts that use the `forward-auth`
middleware, and generates a single Authentik blueprint ConfigMap that creates, for
each host:  proxy provider (forward_single) + application + policy binding (+ the
infra-* group/policy it needs).  configure-oidc.sh then auto-attaches all proxy
providers to the embedded outpost.  Result: any *.int host put behind forward-auth
is automatically protected by Authentik on the next deploy — zero per-app config.

Run from repo root:  python3 scripts/generate-forward-auth-blueprint.py
Wired into the deploy pipeline (see deploy-local.sh) so it runs before ArgoCD sync.
"""
import re
import glob
import os

BASE = os.environ.get("INTERNAL_DOMAIN", "int." + os.environ.get("BASE_DOMAIN", "example.com"))
ROUTES_GLOB = "kubernetes/**/*.yaml"
OUT = "kubernetes/platform/authentik/manifests/blueprint-forward-auth.yaml"

# Per-subdomain group mapping. Anything not listed → admins-only.
# Adding a host to a group here is the ONLY manual step ever needed (and optional).
GROUP = {
    "proxmox": "infra-proxmox", "truenas": "infra-truenas",
    "vault1": "infra-vault", "openbao": "infra-vault",
    "adguard": "infra-network", "portainer": "infra-containers",
    "portainer2": "infra-containers", "longhorn": "infra-storage",
    "argocd": "infra-gitops", "ansible": "infra-automation",
}
# Hosts that must NOT get forward-auth even if matched (machine/non-browser).
EXCLUDE_SUBS = {"api", "registry", "plex"}

def _existing_hosts():
    """external_host values already defined as proxy providers in blueprint-apps.yaml."""
    try:
        txt=open("kubernetes/platform/authentik/manifests/blueprint-apps.yaml").read()
    except FileNotFoundError:
        return set()
    return set(re.findall(r'external_host:\s*"([^"]+)"', txt))

def discover_hosts():
    """Return {sub: full_host} for every IngressRoute using forward-auth."""
    hosts = {}
    for f in glob.glob(ROUTES_GLOB, recursive=True):
        txt = open(f).read()
        for doc in txt.split("\n---\n"):
            if "kind: IngressRoute" not in doc or "name: forward-auth" not in doc:
                continue
            for m in re.finditer(r'Host\(`([^`]+)`\)', doc):
                host = m.group(1)
                if host.endswith(BASE):
                    sub = host.split(".")[0]
                    if sub not in EXCLUDE_SUBS:
                        hosts[sub] = host
    covered = _existing_hosts()
    hosts = {sub: h for sub, h in hosts.items() if f'https://{h}' not in covered}
    return dict(sorted(hosts.items()))

def title(sub):
    return sub.replace("-", " ").title()

def main():
    hosts = discover_hosts()
    groups = sorted({g for s, g in GROUP.items() if s in hosts})
    e = []  # blueprint entries (6-space indented under entries:)

    e.append("      # ── Groups (auto: infra-* scopes referenced by discovered hosts) ──")
    for g in groups:
        e.append(f"""      - model: authentik_core.group
        state: present
        identifiers: {{ name: {g} }}
        attrs: {{ name: {g}, is_superuser: false }}""")

    e.append("      # ── Policies (admins OR <group>; admins always above) ──")
    for g in groups:
        e.append(f"""      - model: authentik_policies_expression.expressionpolicy
        state: present
        identifiers: {{ name: policy-{g} }}
        attrs:
          name: policy-{g}
          expression: |
            return (ak_is_group_member(request.user, name="platform-admins")
                    or ak_is_group_member(request.user, name="{g}"))""")

    e.append("      # ── Forward-auth proxy providers + applications + bindings (auto) ──")
    for sub, host in hosts.items():
        slug = f"{sub}-fwd"
        pname = f"{title(sub)} Forward-Auth Provider"
        policy = f"policy-{GROUP[sub]}" if sub in GROUP else "policy-admins-only"
        # refresh_token_validity is pinned rather than left to Authentik's
        # `days=30` model default. ProxyProvider subclasses OAuth2Provider, so
        # it carries the field even though the forward-auth outpost does not
        # request offline_access today and therefore holds no refresh token.
        # It is set here because this template is the ONLY thing standing
        # between a newly discovered *.int host and a live provider — a host
        # added tomorrow must not inherit a 30-day credential ceiling by
        # default. See the header of manifests/blueprint-apps.yaml for why
        # days=30 is worse than it looks (refresh tokens outlive their session
        # and rotation resets their expiry).
        e.append(f"""      - model: authentik_providers_proxy.proxyprovider
        state: present
        identifiers: {{ name: {pname} }}
        attrs:
          name: {pname}
          mode: forward_single
          external_host: "https://{host}"
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          refresh_token_validity: days=1
      - model: authentik_core.application
        state: present
        identifiers: {{ slug: {slug} }}
        attrs:
          name: {title(sub)} (forward-auth)
          slug: {slug}
          provider: !Find [authentik_providers_proxy.proxyprovider, [name, {pname}]]
          policy_engine_mode: any
      - model: authentik_policies.policybinding
        state: present
        identifiers:
          target: !Find [authentik_core.application, [slug, {slug}]]
          order: 10
        attrs:
          target: !Find [authentik_core.application, [slug, {slug}]]
          policy: !Find [authentik_policies_expression.expressionpolicy, [name, {policy}]]
          enabled: true
          order: 10
          negate: false
          timeout: 30""")

    body = "\n".join(e)
    out = f"""---
# AUTO-GENERATED by scripts/generate-forward-auth-blueprint.py — DO NOT EDIT BY HAND.
# Regenerated on every deploy: every *.int IngressRoute using the forward-auth
# middleware automatically gets an Authentik proxy provider + application + policy.
# To scope a host to a group, edit GROUP in the generator. configure-oidc.sh attaches
# all proxy providers to the embedded outpost.
apiVersion: v1
kind: ConfigMap
metadata:
  name: authentik-blueprint-forward-auth
  namespace: authentik
  annotations:
    argocd.argoproj.io/sync-options: ServerSideApply=true
data:
  forward-auth.yaml: |
    version: 1
    metadata:
      name: Forward-Auth (auto-generated)
    entries:
{body}
"""
    open(OUT, "w").write(out)
    print(f"generated {OUT}: {len(hosts)} forward-auth hosts → {sorted(hosts)}")
    print(f"groups: {groups}")

if __name__ == "__main__":
    main()
