#!/usr/bin/env bash
# scripts/sync-groups.sh — Sync platform.yaml groups to ArgoCD ApplicationSets
#
# Reads groups: from platform.yaml and:
#   - Regenerates ALL mandatory ApplicationSets (appset-core.yaml, applicationset-root.yaml)
#   - Creates appset-core-<group>.yaml in kubernetes/bootstrap/ for enabled groups
#   - Deletes appset-core-<group>.yaml for disabled groups
#   - Updates replicas: field in kubernetes/<tier>/<app>/application.yaml
#   - Manages companion bootstrap files (app-*.yaml.disabled) for optional apps
#     Companions are tracked in COMPANIONS map in the Python block below.
#     When an app/group is enabled:  app-X.yaml.disabled → app-X.yaml (applied by deploy-argocd.sh)
#     When an app/group is disabled: app-X.yaml           → app-X.yaml.disabled (skipped by glob)
#
# Also syncs catalog ha: replicas to catalog application.yaml files.
#
# Usage: scripts/sync-groups.sh [--dry-run] [--repo-root <path>]
set -euo pipefail

SCRIPT_NAME="sync-groups"
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRY_RUN=false
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

PLATFORM_FILE="$REPO_ROOT/platform.yaml"
BOOTSTRAP_DIR="$REPO_ROOT/kubernetes/bootstrap"
CHANGED_FILE="$REPO_ROOT/.sync-groups-changed"

if [[ ! -f "$PLATFORM_FILE" ]]; then
  echo "ERROR: $PLATFORM_FILE not found"
  exit 1
fi

echo "==> sync-groups.sh starting (dry_run=$DRY_RUN, repo=$REPO_ROOT)"

export DRY_RUN REPO_ROOT PLATFORM_FILE BOOTSTRAP_DIR CHANGED_FILE

# Run the main logic via python3
python3 << 'PYEOF'
import os, sys, yaml

dry_run       = os.environ['DRY_RUN'] == 'true'
repo_root     = os.environ['REPO_ROOT']
platform_file = os.environ['PLATFORM_FILE']
bootstrap_dir = os.environ['BOOTSTRAP_DIR']
changed_file  = os.environ['CHANGED_FILE']
changed_files = []

with open(platform_file) as fh:
    data = yaml.safe_load(fh)

REPO_URL = os.environ.get("GIT_REPO_URL", "https://github.com/your-org/your-repo") + ".git"

def appset_yaml(appset_name, appset_label, metadata_name, path_pattern, comment, managed_comment, automated_prune="false"):
    """Generate a full ApplicationSet YAML — single source of truth for all AppSets."""
    return (
        f"---\n"
        f"# {comment}\n"
        f"# {managed_comment}\n"
        f"apiVersion: argoproj.io/v1alpha1\n"
        f"kind: ApplicationSet\n"
        f"metadata:\n"
        f"  name: {metadata_name}\n"
        f"  namespace: argocd\n"
        f"spec:\n"
        f"  goTemplate: true\n"
        f'  goTemplateOptions: ["missingkey=zero"]\n'
        f"  generators:\n"
        f"    - git:\n"
        f"        repoURL: {REPO_URL}\n"
        f"        revision: HEAD\n"
        f"        files:\n"
        f'          - path: "{path_pattern}"\n'
        f"  template:\n"
        f"    metadata:\n"
        f"      name: '{{{{ index (splitList \"/\" .path.path) 1 }}}}-{{{{ index (splitList \"/\" .path.path) 2 }}}}'\n"
        f"      namespace: argocd\n"
        f"    spec:\n"
        f"      project: platform\n"
        f"      sources:\n"
        f"        - repoURL: {REPO_URL}\n"
        f"          targetRevision: HEAD\n"
        f"          ref: values\n"
        f'        - repoURL: "{{{{ .repoURL }}}}"\n'
        f'          targetRevision: "{{{{ .targetRevision }}}}"\n'
        f'          chart: "{{{{ .chart }}}}"\n'
        f"          helm:\n"
        f'            releaseName: "{{{{ .releaseName }}}}"\n'
        f"            valueFiles:\n"
        f'              - "$values/{{{{ .path.path }}}}/values.yaml"\n'
        f"            parameters:\n"
        f"              - name: replicaCount\n"
        f"                value: '{{{{ if .replicas }}}}{{{{ .replicas }}}}{{{{ else }}}}1{{{{ end }}}}'\n"
        f"      destination:\n"
        f"        server: https://kubernetes.default.svc\n"
        f'        namespace: "{{{{ .namespace }}}}"\n'
        f"      syncPolicy:\n"
        f"        automated:\n"
        f"          prune: {automated_prune}\n"
        f"          selfHeal: true\n"
        f"        retry:\n"
        f"          limit: 5\n"
        f"          backoff:\n"
        f"            duration: 5s\n"
        f"            factor: 2\n"
        f"            maxDuration: 3m\n"
        f"        syncOptions:\n"
        f"          - CreateNamespace=true\n"
        f"          - '{{{{ if eq (default \"true\" .serverSideApply) \"false\" }}}}ServerSideApply=false{{{{ else }}}}ServerSideApply=true{{{{ end }}}}'\n"
        f"          - RespectIgnoreDifferences=true\n"
        f"      ignoreDifferences:\n"
        f"        - kind: Secret\n"
        f"          jqPathExpressions:\n"
        f'            - \'.data["admin-password"]\'\n'
        f'            - \'.data["admin-user"]\'\n'
        f"        - group: external-secrets.io\n"
        f"          kind: ExternalSecret\n"
        f"          jsonPointers:\n"
        f"            - /status\n"
        f"            - /metadata/finalizers\n"
        f"          jqPathExpressions:\n"
        f"            - '.spec.data[].remoteRef.conversionStrategy'\n"
        f"            - '.spec.data[].remoteRef.decodingStrategy'\n"
        f"            - '.spec.data[].remoteRef.metadataPolicy'\n"
        f"        - group: apps\n"
        f"          kind: StatefulSet\n"
        f"          jsonPointers:\n"
        f"            - /spec/persistentVolumeClaimRetentionPolicy\n"
        f"          managedFieldsManagers:\n"
        f"            - kube-controller-manager\n"
    )

def write_if_changed(filepath, content, label=""):
    """Write file only if content differs. Returns True if changed."""
    existing = open(filepath).read() if os.path.exists(filepath) else ''
    if existing == content:
        print(f"  ⏭  {label or filepath} unchanged")
        return False
    if dry_run:
        print(f"[DRY-RUN] Would write {filepath}")
        return False
    with open(filepath, 'w') as fh:
        fh.write(content)
    print(f"  ✅ Created/updated {filepath}")
    return True

def update_replicas_in_file(filepath, replicas_str):
    """Add or update 'replicas: "N"' in a YAML file. Returns True if changed."""
    with open(filepath) as fh:
        lines = fh.readlines()
    new_lines = []
    found = False
    for line in lines:
        if line.startswith('replicas:'):
            new_val = f'replicas: "{replicas_str}"\n'
            if line.rstrip('\n') == new_val.rstrip('\n'):
                return False
            new_lines.append(new_val)
            found = True
        else:
            new_lines.append(line)
    if not found:
        new_lines.append(f'replicas: "{replicas_str}"\n')
    if dry_run:
        print(f"[DRY-RUN] Would update replicas in {filepath}")
        return False
    with open(filepath, 'w') as fh:
        fh.writelines(new_lines)
    return True

# ── Generate mandatory ApplicationSets ───────────────────────────────────────
print("\n==> Regenerating mandatory ApplicationSets...")

# appset-core.yaml — always present, discovers kubernetes/core/*/application.yaml
core_content = appset_yaml(
    appset_name="appset-core",
    appset_label="platform-core",
    metadata_name="platform-core",
    path_pattern="kubernetes/core/*/application.yaml",
    comment="appset-core.yaml — Mandatory ApplicationSet for kubernetes/core/ tier.",
    managed_comment="This file is regenerated by scripts/sync-groups.sh — do not edit manually"
)
if write_if_changed(os.path.join(bootstrap_dir, 'appset-core.yaml'), core_content, 'appset-core.yaml'):
    changed_files.append(os.path.join(bootstrap_dir, 'appset-core.yaml'))

# applicationset-root.yaml — always present, discovers catalog+apps tiers
root_content = appset_yaml(
    appset_name="applicationset-root",
    appset_label="platform-catalog-apps",
    metadata_name="platform-catalog-apps",
    path_pattern="kubernetes/{catalog,apps}/*/application.yaml",
    comment="applicationset-root.yaml — ApplicationSet for kubernetes/catalog/ and kubernetes/apps/ tiers.",
    managed_comment="This file is regenerated by scripts/sync-groups.sh — do not edit manually"
)
if write_if_changed(os.path.join(bootstrap_dir, 'applicationset-root.yaml'), root_content, 'applicationset-root.yaml'):
    changed_files.append(os.path.join(bootstrap_dir, 'applicationset-root.yaml'))

# ── Process optional groups ────────────────────────────────────────────────────
print("\n==> Processing optional group ApplicationSets...")
groups = data.get('groups', {})
for group_name, group_cfg in groups.items():
    enabled  = group_cfg.get('enabled', False)
    tier     = group_name[len('core-'):] if group_name.startswith('core-') else group_name
    appset_f = os.path.join(bootstrap_dir, f'appset-{group_name}.yaml')

    if enabled:
        content = appset_yaml(
            appset_name=f"appset-{group_name}",
            appset_label=f"platform-{tier}",
            metadata_name=f"platform-{tier}",
            path_pattern=f"kubernetes/{tier}/*/application.yaml",
            comment=f"appset-{group_name}.yaml — Auto-generated by scripts/sync-groups.sh",
            managed_comment=f"Source: platform.yaml groups.{group_name} — DO NOT edit manually",
            automated_prune="true" if group_name == "core-monitoring" else "false"
        )
        if write_if_changed(appset_f, content, f'appset-{group_name}.yaml'):
            changed_files.append(appset_f)

        # Update replicas and enabled/disabled state in application.yaml files
        for app_name, app_cfg in (group_cfg.get('apps') or {}).items():
            if not app_cfg:
                continue
            app_enabled = app_cfg.get('enabled', True)
            app_yaml         = os.path.join(repo_root, 'kubernetes', tier, app_name, 'application.yaml')
            app_yaml_disabled = os.path.join(repo_root, 'kubernetes', tier, app_name, 'application.yaml.disabled')

            if not app_enabled:
                # Disable: rename application.yaml → application.yaml.disabled
                if os.path.exists(app_yaml):
                    if dry_run:
                        print(f"[DRY-RUN] Would disable {tier}/{app_name} (rename application.yaml)")
                    else:
                        os.rename(app_yaml, app_yaml_disabled)
                        print(f"  🚫 Disabled {tier}/{app_name} (renamed application.yaml → .disabled)")
                        changed_files.append(app_yaml)
                else:
                    print(f"  ⏭  {tier}/{app_name} already disabled")
                continue

            # enabled=True: restore application.yaml.disabled if present
            if os.path.exists(app_yaml_disabled) and not os.path.exists(app_yaml):
                if dry_run:
                    print(f"[DRY-RUN] Would re-enable {tier}/{app_name}")
                else:
                    os.rename(app_yaml_disabled, app_yaml)
                    print(f"  ✅ Re-enabled {tier}/{app_name} (restored application.yaml)")
                    changed_files.append(app_yaml)

            replicas = app_cfg.get('replicas')
            if replicas is None:
                continue
            if not os.path.exists(app_yaml):
                print(f"  ⚠  No application.yaml for {tier}/{app_name} — skipping")
                continue
            if update_replicas_in_file(app_yaml, str(replicas)):
                print(f"  ✅ Updated {tier}/{app_name} replicas: {replicas}")
                changed_files.append(app_yaml)
            else:
                print(f"  ⏭  {tier}/{app_name} replicas already {replicas}")
    else:
        if os.path.exists(appset_f):
            if dry_run:
                print(f"[DRY-RUN] Would delete {appset_f}")
            else:
                os.remove(appset_f)
                print(f"  🗑  Deleted {appset_f} (group disabled)")
                changed_files.append(appset_f)
        else:
            print(f"  ⏭  {appset_f} already absent")

# ── Companion bootstrap file management ───────────────────────────────────────
# Maps group names and group.app_name keys to standalone bootstrap files that
# must be enabled/disabled together with their parent group or app.
# Files are in kubernetes/bootstrap/ and toggled via .disabled extension.
COMPANIONS = {
    # When core-monitoring group is enabled/disabled, toggle all its companion bootstrap files
    "core-monitoring": [
        "app-alertmanager-discord.yaml",
        "app-monitoring-alerts.yaml",
        "app-monitoring-grafana-dashboards.yaml",
        "app-monitoring-manifests.yaml",
    ],
    # Per-app companions within core-platform
    "core-platform.grafana": [
        "app-grafana-manifests.yaml",
    ],
    "core-platform.falco": [
        "app-falco-manifests.yaml",
    ],
    "core-platform.velero": [
        "app-velero.yaml",
    ],
    "core-platform.minio-velero": [
        "app-minio-velero.yaml",
    ],
    "core-platform.argocd-image-updater": [
        "app-argocd-image-updater.yaml",
    ],
    "core-platform.external-dns": [
        "app-external-dns-helm.yaml",
        "app-external-dns-manifests.yaml",
    ],
}

def manage_companions(key, enabled):
    """Enable or disable companion bootstrap files for a group or app key."""
    companions = COMPANIONS.get(key, [])
    if not companions:
        return
    print(f"\n  ==> Companion files for {key} (enabled={enabled}):")
    for fname in companions:
        active   = os.path.join(bootstrap_dir, fname)
        disabled = os.path.join(bootstrap_dir, fname + '.disabled')
        if enabled:
            if os.path.exists(disabled):
                if dry_run:
                    print(f"  [DRY-RUN] Would restore companion: {fname}")
                else:
                    os.rename(disabled, active)
                    print(f"    ✅ Restored companion: {fname}")
                    changed_files.append(active)
            elif os.path.exists(active):
                print(f"    ⏭  Companion {fname} already active")
            else:
                print(f"    ⚠  Companion {fname} not found (neither active nor .disabled)")
        else:
            if os.path.exists(active):
                if dry_run:
                    print(f"  [DRY-RUN] Would disable companion: {fname}")
                else:
                    os.rename(active, disabled)
                    print(f"    🚫 Disabled companion: {fname}")
                    changed_files.append(disabled)
            elif os.path.exists(disabled):
                print(f"    ⏭  Companion {fname} already disabled")
            else:
                print(f"    ⚠  Companion {fname} not found (neither active nor .disabled)")

print("\n==> Processing companion bootstrap files...")
for group_name, group_cfg in groups.items():
    group_enabled = group_cfg.get('enabled', False)
    # Manage group-level companions
    manage_companions(group_name, group_enabled)

    if group_enabled:
        # When group is enabled, manage per-app companions too
        for app_name, app_cfg in (group_cfg.get('apps') or {}).items():
            if not app_cfg:
                continue
            app_enabled = app_cfg.get('enabled', True)
            companion_key = f"{group_name}.{app_name}"
            manage_companions(companion_key, app_enabled)
    else:
        # When whole group is disabled, disable all per-app companions too
        for app_name in (group_cfg.get('apps') or {}):
            companion_key = f"{group_name}.{app_name}"
            manage_companions(companion_key, False)

# ── Process catalog ha: replicas ──────────────────────────────────────────────
print("\n==> Processing catalog HA replicas...")
catalog = data.get('catalog', {})
ha_cfg  = catalog.get('ha', {}) if isinstance(catalog, dict) else {}
for app_name, app_ha in (ha_cfg or {}).items():
    if not app_ha:
        continue
    replicas = app_ha.get('replicas')
    if replicas is None:
        continue
    cat_yaml = os.path.join(repo_root, 'kubernetes', 'catalog', app_name, 'catalog.yaml')
    if not os.path.exists(cat_yaml):
        print(f"  ⚠  No catalog.yaml for catalog/{app_name} — skipping")
        continue
    if update_replicas_in_file(cat_yaml, str(replicas)):
        print(f"  ✅ Updated catalog/{app_name} replicas: {replicas}")
        changed_files.append(cat_yaml)
    else:
        print(f"  ⏭  catalog/{app_name} replicas already {replicas}")

if changed_files:
    print(f"\n==> {len(changed_files)} file(s) changed")
    with open(changed_file, 'w') as fh:
        fh.write('\n'.join(changed_files))
else:
    print("\n==> No changes needed")
PYEOF

# ── Commit if changes were made ───────────────────────────────────────────────
if [[ -f "$CHANGED_FILE" ]] && ! $DRY_RUN; then
  rm -f "$CHANGED_FILE"
  cd "$REPO_ROOT"
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "chore: sync groups from platform.yaml [skip ci]

Auto-generated by scripts/sync-groups.sh

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
    echo "==> ✅ Committed group changes"
  else
    echo "==> No git changes to commit"
  fi
else
  rm -f "$CHANGED_FILE" 2>/dev/null || true
  $DRY_RUN || echo "==> No changes — nothing to commit"
fi

echo "==> Done"
