# kubernetes/catalog/ — Optional App Library

This directory contains **catalog apps** — applications that are supported by the platform
but not always deployed. They are enabled or disabled via `platform.yaml` at the repo root.

## How It Works

```
platform.yaml           ← Edit this to enable/disable apps
    ↓ (CI reads)
scripts/sync-catalog.sh ← Generates/removes ArgoCD Application bootstrap files
    ↓
kubernetes/bootstrap/   ← catalog-<app>.yaml files (auto-generated)
    ↓
ArgoCD                  ← Deploys/removes the app
```

## Adding a New Catalog App

1. Create `kubernetes/catalog/<app-name>/` using the `_template/` as a reference
2. Add a `catalog.yaml` with source metadata (not `application.yaml` — that would be auto-discovered)
3. Add your Helm values in `values.yaml` (if Helm chart)
4. Add raw manifests in `manifests/` (Namespace, NetworkPolicy, ExternalSecret, etc.)
5. Add your app name to `platform.yaml` under `catalog.enabled`
6. Push — CI generates the bootstrap files and ArgoCD deploys

## Removing an App

1. Remove the app name from `platform.yaml`
2. Push — CI removes the bootstrap files
3. ArgoCD (with `resources-finalizer`) deletes all app resources

## Directory Structure

```
catalog/
├── README.md
├── _template/          ← Template for new apps (copy this)
│   ├── catalog.yaml    ← Source definition (Helm chart or raw manifests)
│   ├── values.yaml     ← Helm values (optional)
│   └── manifests/      ← Raw K8s resources
│       ├── namespace.yaml
│       ├── networkpolicy.yaml
│       └── ...
├── wiki/               ← Wiki.js (wiki.int.${BASE_DOMAIN})
│   ├── catalog.yaml
│   ├── values.yaml
│   └── manifests/
└── <your-app>/
```

## Catalog App List

| App | Description | URL |
|-----|-------------|-----|
| wiki | Wiki.js documentation wiki | wiki.int.${BASE_DOMAIN} |
| gatus | Uptime/status monitoring | status.int.${BASE_DOMAIN} |
| gitea | Self-hosted Git forge | gitea.int.${BASE_DOMAIN} |
| forgejo | Community Git forge (Gitea fork) | forgejo.int.${BASE_DOMAIN} |
| vaultwarden | Bitwarden-compatible password manager | vaultwarden.int.${BASE_DOMAIN} |
| it-tools | IT/Dev tool collection | it-tools.int.${BASE_DOMAIN} |
| stirling-pdf | PDF manipulation tools | stirling-pdf.int.${BASE_DOMAIN} |
| excalidraw | Collaborative whiteboard | excalidraw.int.${BASE_DOMAIN} |
| actual | Personal finance / budgeting | actual.int.${BASE_DOMAIN} |
| n8n | Workflow automation | n8n.int.${BASE_DOMAIN} |
| code-server | VS Code in the browser | code-server.int.${BASE_DOMAIN} |
| jellyfin | Media server | jellyfin.int.${BASE_DOMAIN} |
| ntfy | Push notification server | ntfy.int.${BASE_DOMAIN} |
| linkding | Bookmark manager | linkding.int.${BASE_DOMAIN} |
| navidrome | Music streaming server | navidrome.int.${BASE_DOMAIN} |
| speedtest-tracker | Internet speed monitoring | speedtest-tracker.int.${BASE_DOMAIN} |
| searxng | Private meta search engine | searxng.int.${BASE_DOMAIN} |
| grocy | Household & grocery management | grocy.int.${BASE_DOMAIN} |
| immich | Photo backup & management (postgres + redis) | immich.int.${BASE_DOMAIN} |
| outline | Team knowledge base with OIDC (postgres + redis) | outline.int.${BASE_DOMAIN} |

See `platform.yaml` at repo root for the currently enabled apps.
