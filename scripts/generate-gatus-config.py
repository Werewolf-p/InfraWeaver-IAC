#!/usr/bin/env python3
"""
generate-gatus-config.py — Generates Gatus monitoring config from platform.yaml.

Run this script after editing platform.yaml to keep Gatus endpoints in sync
with what is actually deployed. The output is written directly to the Gatus
manifest and committed to git; ArgoCD syncs it to the cluster.

Usage:
    python3 scripts/generate-gatus-config.py
    # or with explicit paths:
    python3 scripts/generate-gatus-config.py --platform platform.yaml \
        --output kubernetes/catalog/gatus/manifests/all.yaml
"""

import argparse
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML not installed. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

BASE_DOMAIN = os.environ.get("BASE_DOMAIN", "yourdomain.com")

# ── Endpoint registry ─────────────────────────────────────────────────────────
# Maps each app key (as used in platform.yaml) to its Gatus endpoint config.
# "group" is used to section endpoints in the Gatus UI.
# Internal URLs (*.int.yourdomain.com) use `client.insecure: true` because
# they use the wildcard self-signed cert from the internal issuer.

CORE_ENDPOINTS = [
    # Always monitored — these are the mandatory core services.
    {
        "name": "ArgoCD",
        "url": "https://argocd.int.yourdomain.com",
        "interval": "60s",
        "group": "core",
        "client": {"insecure": True},
        "conditions": ["[STATUS] == 200", "[RESPONSE_TIME] < 2000"],
        "alerts": [{"type": "discord", "description": "ArgoCD is unreachable via VPN"}],
    },
    {
        "name": "Traefik",
        # Internal K8s service URL — uses the traefik entrypoint (port 8080).
        "url": "http://traefik-dashboard.traefik.svc.cluster.local:8080/ping",
        "interval": "60s",
        "group": "core",
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Traefik ingress is unreachable — all internal services affected"}],
    },
    {
        "name": "OpenBao",
        "url": "https://openbao.int.yourdomain.com/v1/sys/health",
        "interval": "60s",
        "group": "core",
        "client": {"insecure": True},
        "conditions": ["[STATUS] == 200", "[BODY].initialized == true", "[BODY].sealed == false"],
        "alerts": [{"type": "discord", "description": "OpenBao is sealed or unreachable — secrets unavailable"}],
    },
]

EXTERNAL_ENDPOINTS = [
    {
        "name": "Cloudflare DNS",
        # Use the Cloudflare public DNS resolver directly (not DOH) — simple TCP health check
        "url": "https://cloudflare.com",
        "interval": "300s",
        "group": "external",
        "conditions": ["[STATUS] < 500"],
        "alerts": [{"type": "discord", "description": "Cloudflare unreachable — external DNS may be failing"}],
    },
    {
        "name": "Let's Encrypt ACME",
        "url": "https://acme-v02.api.letsencrypt.org/directory",
        "interval": "300s",
        "group": "external",
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Let's Encrypt ACME unreachable — cert renewal may fail"}],
    },
]

# Map: platform.yaml app key → Gatus endpoint definition
# Keys match the `apps:` keys inside each group, or catalog `enabled` list.
APP_ENDPOINT_MAP = {
    # ── core-platform ──────────────────────────────────────────────────────────
    "authentik": {
        "name": "Authentik SSO",
        "url": "https://auth.yourdomain.com/-/health/ready/",
        "interval": "60s",
        "group": "platform",
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Authentik SSO is down — all platform logins affected"}],
    },
    "grafana": {
        "name": "Grafana",
        "url": "https://grafana.int.yourdomain.com/api/health",
        "interval": "60s",
        "group": "platform",
        "client": {"insecure": True},
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Grafana is unreachable"}],
    },
    # ── core-monitoring ────────────────────────────────────────────────────────
    "kube-prometheus-stack": {
        "name": "Prometheus",
        "url": "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/-/healthy",
        "interval": "60s",
        "group": "monitoring",
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Prometheus is unreachable — metrics collection stopped"}],
    },
    "loki": {
        "name": "Loki",
        "url": "http://loki.monitoring.svc.cluster.local:3100/ready",
        "interval": "120s",
        "group": "monitoring",
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Loki is unreachable — log aggregation stopped"}],
    },
    # ── catalog apps ───────────────────────────────────────────────────────────
    "wiki": {
        "name": "Wiki.js",
        "url": "https://wiki.int.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Wiki.js is unreachable"}],
    },
    "stirling-pdf": {
        "name": "Stirling PDF",
        "url": "https://stirling-pdf.int.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Stirling PDF is unreachable"}],
    },
    "onedev": {
        "name": "OneDev (Git + CI)",
        "url": "https://onedev.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "OneDev is unreachable"}],
    },
    "infraweaver-console": {
        "name": "InfraWeaver Console",
        "url": "https://infraweaver.int.yourdomain.com/api/ping",
        "interval": "60s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] == 200", "[BODY].status == ok"],
        "alerts": [{"type": "discord", "description": "InfraWeaver Console is unreachable"}],
    },
    "registry": {
        "name": "Container Registry",
        "url": "https://registry.int.yourdomain.com/v2/",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] < 500"],
        "alerts": [{"type": "discord", "description": "Container registry is unreachable"}],
    },
    "uptime-kuma": {
        "name": "Uptime Kuma",
        "url": "https://uptime-kuma.int.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Uptime Kuma is unreachable"}],
    },
    "gitea": {
        "name": "Gitea",
        "url": "https://gitea.int.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] < 400"],
        "alerts": [{"type": "discord", "description": "Gitea is unreachable"}],
    },
    "forgejo": {
        "name": "Forgejo",
        "url": "https://forgejo.int.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] < 400"],
        "alerts": [{"type": "discord", "description": "Forgejo is unreachable"}],
    },
    "vaultwarden": {
        "name": "Vaultwarden",
        "url": "https://vaultwarden.int.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Vaultwarden is unreachable"}],
    },
    "n8n": {
        "name": "n8n Automation",
        "url": "https://n8n.int.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] < 400"],
        "alerts": [{"type": "discord", "description": "n8n is unreachable"}],
    },
    "actual": {
        "name": "Actual Budget",
        "url": "https://actual.int.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Actual Budget is unreachable"}],
    },
    "it-tools": {
        "name": "IT Tools",
        "url": "https://it-tools.int.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "IT Tools is unreachable"}],
    },
    "excalidraw": {
        "name": "Excalidraw",
        "url": "https://excalidraw.int.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] == 200"],
        "alerts": [{"type": "discord", "description": "Excalidraw is unreachable"}],
    },
    "wazuh": {
        "name": "Wazuh Dashboard",
        "url": "https://wazuh.int.yourdomain.com",
        "interval": "120s",
        "group": "catalog",
        "client": {"insecure": True},
        "conditions": ["[STATUS] < 500"],
        "alerts": [{"type": "discord", "description": "Wazuh Dashboard is unreachable"}],
    },
}

# ── YAML template for the ConfigMap header/footer ─────────────────────────────
CONFIGMAP_HEADER = """\
---
apiVersion: v1
kind: Namespace
metadata:
  name: gatus
  labels:
    app.kubernetes.io/name: gatus
    infraweaver.io/type: catalog-app
---
# Gatus config — AUTO-GENERATED from platform.yaml
# DO NOT edit this ConfigMap manually. Run:
#   python3 scripts/generate-gatus-config.py
# to regenerate after changing platform.yaml.
apiVersion: v1
kind: ConfigMap
metadata:
  name: gatus-config
  namespace: gatus
data:
  config.yaml: |
    web:
      port: 8080

    storage:
      type: memory

    alerting:
      discord:
        webhook-url: "${DISCORD_WEBHOOK_URL}"
        default-alert:
          description: "InfraWeaver platform health alert"
          send-on-resolved: true
          failure-threshold: 5
          success-threshold: 2

    endpoints:
"""

CONFIGMAP_FOOTER = """\
---
# ExternalSecret — pulls Discord webhook URL from OpenBao
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: gatus-discord-secret
  namespace: gatus
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: gatus-discord-secret
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: DISCORD_WEBHOOK_URL
      remoteRef:
        key: secret/platform/discord
        property: webhook_url
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
---
# Deployment — Gatus status page
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gatus
  namespace: gatus
  labels:
    app.kubernetes.io/name: gatus
    app.kubernetes.io/instance: gatus
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: gatus
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gatus
      annotations:
        config-version: "1"
    spec:
      priorityClassName: platform-standard
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: gatus
          image: twinproduction/gatus:v5.12.1
          ports:
            - containerPort: 8080
              name: http
          env:
            - name: DISCORD_WEBHOOK_URL
              valueFrom:
                secretKeyRef:
                  name: gatus-discord-secret
                  key: DISCORD_WEBHOOK_URL
          volumeMounts:
            - name: config
              mountPath: /config
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 30
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
      volumes:
        - name: config
          configMap:
            name: gatus-config
---
apiVersion: v1
kind: Service
metadata:
  name: gatus
  namespace: gatus
  labels:
    app.kubernetes.io/name: gatus
spec:
  selector:
    app.kubernetes.io/name: gatus
  ports:
    - port: 8080
      targetPort: 8080
      name: http
---
# IngressRoute — status.int.yourdomain.com (VPN-only, Authentik forward-auth)
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: gatus
  namespace: gatus
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`status.int.yourdomain.com`)
      kind: Rule
      middlewares:
        - name: authentik-forward-auth
          namespace: authentik
        - name: security-headers
          namespace: traefik
      services:
        - name: gatus
          port: 8080
  tls:
    secretName: platform-wildcard-int-tls
---
# NetworkPolicy for Gatus
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-gatus-ingress
  namespace: gatus
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: gatus
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
      ports:
        - protocol: TCP
          port: 8080
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 8080
"""


def indent(text: str, spaces: int) -> str:
    pad = " " * spaces
    return "\n".join(pad + line if line.strip() else line for line in text.splitlines())


def endpoint_to_yaml(ep: dict) -> str:
    """Render a single endpoint dict as indented YAML lines for the ConfigMap."""
    lines = []
    lines.append(f"      - name: {ep['name']}")
    lines.append(f"        url: {ep['url']}")
    lines.append(f"        interval: {ep['interval']}")
    if "group" in ep:
        lines.append(f"        group: {ep['group']}")
    if ep.get("client"):
        lines.append("        client:")
        if ep["client"].get("insecure"):
            lines.append("          insecure: true")
    lines.append("        conditions:")
    for c in ep["conditions"]:
        lines.append(f'          - "{c}"')
    if ep.get("alerts"):
        lines.append("        alerts:")
        for a in ep["alerts"]:
            lines.append(f"          - type: {a['type']}")
            lines.append(f"            description: \"{a['description']}\"")
    return "\n".join(lines)


def build_enabled_set(platform: dict) -> set:
    """Return the set of app keys that are enabled based on platform.yaml.

    An app is considered enabled when:
    - Its parent group has enabled: true (or no enabled key, defaulting to true)
    - The app itself does not have enabled: false set explicitly
    - OR it appears in catalog.enabled list
    """
    enabled = set()

    groups = platform.get("groups", {})
    for group_name, group in groups.items():
        if not group.get("enabled", True):
            continue
        for app_key, app_cfg in group.get("apps", {}).items():
            if app_cfg and app_cfg.get("enabled") is False:
                continue  # explicitly disabled app within an enabled group
            enabled.add(app_key)

    catalog = platform.get("catalog", {})
    for app_key in catalog.get("enabled", []):
        enabled.add(app_key)

    return enabled


def generate(platform_path: Path, output_path: Path) -> None:
    platform = yaml.safe_load(platform_path.read_text())
    enabled = build_enabled_set(platform)

    print(f"Enabled apps from platform.yaml: {sorted(enabled)}")

    endpoints = []

    # Core always-on
    endpoints.extend(CORE_ENDPOINTS)

    # Platform-app-based endpoints
    for app_key, ep_def in APP_ENDPOINT_MAP.items():
        if app_key in enabled:
            endpoints.append(ep_def)
            print(f"  ✓ {ep_def['name']} ({app_key})")
        else:
            print(f"  ✗ {ep_def['name']} ({app_key}) — not enabled, skipped")

    # External always-on
    endpoints.extend(EXTERNAL_ENDPOINTS)

    # Build ConfigMap content
    ep_yaml_blocks = "\n\n".join(endpoint_to_yaml(ep) for ep in endpoints)
    configmap_section = CONFIGMAP_HEADER + ep_yaml_blocks + "\n"

    output = (configmap_section + CONFIGMAP_FOOTER).replace("yourdomain.com", BASE_DOMAIN)
    output_path.write_text(output)
    print(f"\nWrote {len(endpoints)} endpoints to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Generate Gatus config from platform.yaml")
    parser.add_argument("--platform", default="platform.yaml", help="Path to platform.yaml")
    parser.add_argument(
        "--output",
        default="kubernetes/catalog/gatus/manifests/all.yaml",
        help="Output path for the Gatus manifest",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).parent.parent
    platform_path = repo_root / args.platform
    output_path = repo_root / args.output

    if not platform_path.exists():
        print(f"ERROR: {platform_path} not found", file=sys.stderr)
        sys.exit(1)

    generate(platform_path, output_path)


if __name__ == "__main__":
    main()
