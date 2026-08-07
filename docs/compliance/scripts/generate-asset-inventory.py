#!/usr/bin/env python3
"""Render docs/compliance/asset-inventory.md from the platform's real sources.

ISO/IEC 27001:2022 A.5.9 ("Inventory of information and other associated
assets") is only credible if the inventory is regenerated from the systems it
describes rather than hand-maintained until it rots. This script is that
regeneration step.

Sources, in order of authority:
  1. platform.yaml                  — declared platform composition (core apps,
                                      optional groups, catalog apps, NAS
                                      providers, backup provider)
  2. `kubectl get applications`     — what ArgoCD actually reconciles (live)
  3. `kubectl get nodes`            — the compute substrate (live)
  4. `kubectl get ns` / `pvc` / `sc`— namespaces and persistent data (live)
  5. ../../../infrastructure envs/*/nodes.yaml (optional, if the Proxmox repo is
     checked out alongside) — the hypervisor/VM layer beneath Kubernetes

READ-ONLY BY CONSTRUCTION
  Every kubectl invocation is a `get`. There is no apply/patch/delete/exec path
  in this file, and the subprocess helper refuses any verb that is not `get`.
  Running this script cannot change cluster state.

Usage:
  python3 docs/compliance/scripts/generate-asset-inventory.py            # write asset-inventory.md
  python3 docs/compliance/scripts/generate-asset-inventory.py --stdout   # print, write nothing
  python3 docs/compliance/scripts/generate-asset-inventory.py --no-cluster
        # platform.yaml only; use when no kubeconfig is available (e.g. CI).
        # Live sections are then rendered as "not collected" rather than
        # silently omitted, so a stale run is visible as stale.

Exit codes: 0 on success (including partial collection), 1 on unreadable
platform.yaml. Missing cluster access is NOT an error — it is recorded in the
output as an explicit collection gap.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import pathlib
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - environment guard
    sys.stderr.write(
        "error: PyYAML is required. Install with: python3 -m pip install pyyaml\n"
    )
    raise SystemExit(1)

KUBECTL_TIMEOUT_S = 30
UNKNOWN = "unknown"
NOT_COLLECTED = "_not collected — no cluster access at generation time_"


# ── read-only command plumbing ───────────────────────────────────────────────


class CollectionError(RuntimeError):
    """Raised when a live source could not be read. Never fatal on its own."""


def kubectl_json(args: list[str]) -> dict:
    """Run a read-only `kubectl get ... -o json` and parse the result.

    Refuses to run anything that is not a `get`, so this module cannot be
    repurposed into a mutating one by a later edit that only touches the
    argument list.
    """
    if not args or args[0] != "get":
        raise ValueError(f"refusing non-read-only kubectl verb: {args[:1]}")
    cmd = ["kubectl", *args, "-o", "json"]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=KUBECTL_TIMEOUT_S,
            check=False,
        )
    except FileNotFoundError as exc:
        raise CollectionError("kubectl not found on PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise CollectionError(f"kubectl timed out after {KUBECTL_TIMEOUT_S}s") from exc
    if proc.returncode != 0:
        raise CollectionError((proc.stderr or "kubectl failed").strip().splitlines()[0])
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise CollectionError("kubectl returned unparseable JSON") from exc


def load_yaml(path: pathlib.Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


# ── collectors ───────────────────────────────────────────────────────────────


def collect_platform(repo_root: pathlib.Path) -> dict:
    path = repo_root / "platform.yaml"
    if not path.is_file():
        sys.stderr.write(f"error: {path} not found (wrong --repo-root?)\n")
        raise SystemExit(1)
    return load_yaml(path)


def collect_nodes() -> list[dict]:
    data = kubectl_json(["get", "nodes"])
    out = []
    for item in data.get("items", []):
        meta = item.get("metadata", {})
        status = item.get("status", {})
        info = status.get("nodeInfo", {})
        addrs = {a.get("type"): a.get("address") for a in status.get("addresses", [])}
        ready = next(
            (
                c.get("status")
                for c in status.get("conditions", [])
                if c.get("type") == "Ready"
            ),
            UNKNOWN,
        )
        roles = sorted(
            k.split("/", 1)[1]
            for k in meta.get("labels", {})
            if k.startswith("node-role.kubernetes.io/")
        )
        cap = status.get("capacity", {})
        out.append(
            {
                "name": meta.get("name", UNKNOWN),
                "ip": addrs.get("InternalIP", UNKNOWN),
                "roles": ",".join(roles) or "worker",
                "ready": "Ready" if ready == "True" else f"NotReady({ready})",
                "os": info.get("osImage", UNKNOWN),
                "kernel": info.get("kernelVersion", UNKNOWN),
                "kubelet": info.get("kubeletVersion", UNKNOWN),
                "runtime": info.get("containerRuntimeVersion", UNKNOWN),
                "cpu": cap.get("cpu", UNKNOWN),
                "memory": cap.get("memory", UNKNOWN),
            }
        )
    return sorted(out, key=lambda n: n["name"])


def collect_argocd_apps() -> list[dict]:
    data = kubectl_json(["get", "applications.argoproj.io", "-A"])
    out = []
    for item in data.get("items", []):
        meta = item.get("metadata", {})
        spec = item.get("spec", {})
        status = item.get("status", {})
        dest = spec.get("destination", {})
        source = spec.get("source", {}) or (spec.get("sources") or [{}])[0]
        out.append(
            {
                "name": meta.get("name", UNKNOWN),
                "project": spec.get("project", UNKNOWN),
                "namespace": dest.get("namespace", "-"),
                "path": source.get("path", source.get("chart", "-")),
                "sync": status.get("sync", {}).get("status", UNKNOWN),
                "health": status.get("health", {}).get("status", UNKNOWN),
            }
        )
    return sorted(out, key=lambda a: (a["project"], a["name"]))


def collect_namespaces() -> list[dict]:
    data = kubectl_json(["get", "ns"])
    out = []
    for item in data.get("items", []):
        meta = item.get("metadata", {})
        labels = meta.get("labels", {})
        out.append(
            {
                "name": meta.get("name", UNKNOWN),
                "psa_enforce": labels.get("pod-security.kubernetes.io/enforce", "-"),
                "psa_audit": labels.get("pod-security.kubernetes.io/audit", "-"),
            }
        )
    return sorted(out, key=lambda n: n["name"])


def collect_data_stores() -> list[dict]:
    """PersistentVolumeClaims: where state — and therefore risk — actually lives."""
    data = kubectl_json(["get", "pvc", "-A"])
    out = []
    for item in data.get("items", []):
        meta = item.get("metadata", {})
        spec = item.get("spec", {})
        status = item.get("status", {})
        out.append(
            {
                "namespace": meta.get("namespace", UNKNOWN),
                "name": meta.get("name", UNKNOWN),
                "class": spec.get("storageClassName", "-"),
                "size": (status.get("capacity") or spec.get("resources", {}).get("requests", {})).get(
                    "storage", UNKNOWN
                ),
                "phase": status.get("phase", UNKNOWN),
            }
        )
    return sorted(out, key=lambda p: (p["namespace"], p["name"]))


def collect_hypervisor_vms(repo_root: pathlib.Path) -> dict[str, list[dict]]:
    """Read the Proxmox VM inventory from the sibling infrastructure repo, if present.

    The Kubernetes nodes are VMs; an asset inventory that stops at the node
    boundary hides the hypervisor tier where the real capacity risk lives.
    """
    candidates = [
        repo_root.parent / "infrastructure",
        repo_root.parent / "InfraWeaver-base",
    ]
    result: dict[str, list[dict]] = {}
    for base in candidates:
        envs = base / "envs"
        if not envs.is_dir():
            continue
        for env_dir in sorted(p for p in envs.iterdir() if p.is_dir()):
            nodes_file = env_dir / "nodes.yaml"
            if not nodes_file.is_file():
                continue
            try:
                doc = load_yaml(nodes_file)
            except yaml.YAMLError:
                continue
            rows = []
            for vm_name, vm in (doc.get("service_vms") or {}).items():
                vm = vm or {}
                rows.append(
                    {
                        "name": vm_name,
                        "vm_id": vm.get("vm_id", UNKNOWN),
                        "cores": vm.get("cores", UNKNOWN),
                        "memory_mb": vm.get("memory_mb", UNKNOWN),
                        "balloon_mb": vm.get("balloon_mb", "—"),
                        "onboot": vm.get("onboot", UNKNOWN),
                    }
                )
            if rows:
                result[env_dir.name] = sorted(rows, key=lambda v: str(v["vm_id"]))
        if result:
            break
    return result


# ── rendering ────────────────────────────────────────────────────────────────


def md_table(headers: list[str], rows: list[list[str]]) -> str:
    if not rows:
        return "_(none)_\n"
    out = ["| " + " | ".join(headers) + " |"]
    out.append("|" + "|".join("---" for _ in headers) + "|")
    for row in rows:
        out.append("| " + " | ".join(str(c) for c in row) + " |")
    return "\n".join(out) + "\n"


def enabled_apps(section: dict) -> list[tuple[str, str, str]]:
    """Flatten a platform.yaml apps map into (name, enabled, description)."""
    rows = []
    for name, cfg in (section or {}).items():
        cfg = cfg or {}
        enabled = cfg.get("enabled", True)
        rows.append((name, "yes" if enabled else "no", cfg.get("description", "")))
    return sorted(rows)


def render(platform: dict, live: dict, vms: dict, generated_at: str) -> str:
    ident = platform.get("identity", {}) or {}
    doc: list[str] = []
    add = doc.append

    add("<!-- GENERATED FILE — do not edit by hand.")
    add("     Regenerate: python3 docs/compliance/scripts/generate-asset-inventory.py")
    add("     Source of truth: platform.yaml + live cluster (read-only kubectl get). -->")
    add("")
    add("# Asset Inventory")
    add("")
    add("**Control:** ISO/IEC 27001:2022 A.5.9 (inventory of information and other")
    add("associated assets), A.5.12 (classification), A.8.1 (endpoint devices),")
    add("A.8.6 (capacity management). SOC 2 CC3.2, CC6.1.")
    add("")
    add(f"**Generated:** {generated_at} by `docs/compliance/scripts/generate-asset-inventory.py`")
    add("")
    add("**Owner:** Platform Owner (see `docs/compliance/information-security-policy.md` §3).")
    add("")
    add("This file is generated. Hand edits are lost on the next run — change the")
    add("source (`platform.yaml`, the cluster, `envs/*/nodes.yaml`) instead, then")
    add("regenerate. That is deliberate: an inventory nobody can reproduce is not")
    add("evidence.")
    add("")

    collection_gaps = live.get("_errors", {})
    if collection_gaps:
        add("## Collection gaps in this run")
        add("")
        add(
            md_table(
                ["Source", "Reason it was not collected"],
                [[k, v] for k, v in sorted(collection_gaps.items())],
            )
        )

    # 1. Platform identity
    add("## 1. Platform identity")
    add("")
    add(
        md_table(
            ["Field", "Value"],
            [
                ["Brand", ident.get("brandName", UNKNOWN)],
                ["Base domain", ident.get("baseDomain", UNKNOWN)],
                ["Default cluster", ident.get("defaultCluster", UNKNOWN)],
                ["Registry host", ident.get("registryHost", UNKNOWN)],
                ["Identity provider", ident.get("authentikUrl", UNKNOWN)],
                ["GitOps engine", ident.get("argocdUrl", UNKNOWN)],
                ["Backup provider", (platform.get("backup") or {}).get("provider", UNKNOWN)],
            ],
        )
    )
    add(
        "`${...}` tokens are fork placeholders substituted at deploy time from"
        " `.env` (see `docs/gitops-operating-model.md` §0). They are not secrets."
    )
    add("")

    # 2. Compute
    add("## 2. Compute — Kubernetes nodes")
    add("")
    nodes = live.get("nodes")
    if nodes is None:
        add(NOT_COLLECTED)
        add("")
    else:
        add(
            md_table(
                ["Node", "IP", "Roles", "State", "OS", "Kernel", "Kubelet", "Runtime", "vCPU", "Memory"],
                [
                    [
                        n["name"],
                        n["ip"],
                        n["roles"],
                        n["ready"],
                        n["os"],
                        n["kernel"],
                        n["kubelet"],
                        n["runtime"],
                        n["cpu"],
                        n["memory"],
                    ]
                    for n in nodes
                ],
            )
        )
        cp = [n for n in nodes if "control-plane" in n["roles"]]
        if nodes and len(cp) == len(nodes):
            add(
                f"**All {len(nodes)} nodes are control-plane nodes and all are schedulable —"
                " this is a converged cluster: application workloads share the nodes"
                " running etcd and the API server. Accepted risk RISK-01"
                " (`risk-register.md`).**"
            )
            add("")

    # 3. Hypervisor tier
    add("## 3. Hypervisor tier — Proxmox VMs beneath the nodes")
    add("")
    if not vms:
        add(
            "_Proxmox inventory not collected — the `infrastructure` /"
            " `InfraWeaver-base` repo was not found next to this one. Clone it as a"
            " sibling directory to include this tier._"
        )
        add("")
    else:
        for env_name, rows in sorted(vms.items()):
            add(f"### Environment `{env_name}`")
            add("")
            add(
                md_table(
                    ["VM", "VMID", "Cores", "Memory (MB)", "Balloon floor (MB)", "Start on boot"],
                    [
                        [r["name"], r["vm_id"], r["cores"], r["memory_mb"], r["balloon_mb"], r["onboot"]]
                        for r in rows
                    ],
                )
            )
        add(
            "Source: `envs/<env>/nodes.yaml` in the infrastructure repo. These entries"
            " under `service_vms:` are *recorded inventory, not Terraform-managed* —"
            " they are reconciled with `qm set` by hand. `qm config` reports the"
            " staged value, not the running one; only `qm pending` shows what a live"
            " guest actually has. Capacity risk: RISK-05 (`risk-register.md`)."
        )
        add("")

    # 4. Declared platform composition
    add("## 4. Declared platform composition (`platform.yaml`)")
    add("")
    add("### 4.1 Mandatory core (cannot be disabled)")
    add("")
    add(
        md_table(
            ["App", "Enabled", "Purpose"],
            [[n, e, d] for n, e, d in enabled_apps((platform.get("core") or {}).get("apps"))],
        )
    )
    add("### 4.2 Optional groups")
    add("")
    for group_name, group in sorted((platform.get("groups") or {}).items()):
        group = group or {}
        state = "enabled" if group.get("enabled", False) else "disabled"
        add(f"**`{group_name}`** — {group.get('description', '')} (group {state})")
        add("")
        add(
            md_table(
                ["App", "Enabled", "Purpose"],
                [[n, e, d] for n, e, d in enabled_apps(group.get("apps"))],
            )
        )
    add("### 4.3 Catalog applications enabled")
    add("")
    catalog = (platform.get("catalog") or {}).get("enabled") or []
    add(md_table(["Catalog app"], [[c] for c in sorted(catalog)]))

    # 5. Live ArgoCD applications
    add("## 5. Deployed applications — live ArgoCD inventory")
    add("")
    apps = live.get("apps")
    if apps is None:
        add(NOT_COLLECTED)
        add("")
    else:
        by_project: dict[str, int] = {}
        for a in apps:
            by_project[a["project"]] = by_project.get(a["project"], 0) + 1
        add(f"**{len(apps)} ArgoCD Applications** across {len(by_project)} AppProjects.")
        add("")
        add(
            md_table(
                ["AppProject", "Applications"],
                [[k, v] for k, v in sorted(by_project.items())],
            )
        )
        if "default" in by_project:
            add(
                f"**{by_project['default']} applications sit in the unrestricted `default`"
                " AppProject** (no sourceRepos/destination pinning). Gap GAP-H9, owned by"
                " WP1."
            )
            add("")
        add("<details><summary>Full application list</summary>")
        add("")
        add(
            md_table(
                ["Application", "Project", "Namespace", "Source path", "Sync", "Health"],
                [
                    [a["name"], a["project"], a["namespace"], a["path"], a["sync"], a["health"]]
                    for a in apps
                ],
            )
        )
        add("</details>")
        add("")
        unhealthy = [a for a in apps if a["health"] not in ("Healthy", UNKNOWN)]
        if unhealthy:
            add("Applications not Healthy at generation time:")
            add("")
            add(
                md_table(
                    ["Application", "Sync", "Health"],
                    [[a["name"], a["sync"], a["health"]] for a in unhealthy],
                )
            )

    # 6. Namespaces / trust zones
    add("## 6. Trust zones — namespaces and Pod Security Admission level")
    add("")
    namespaces = live.get("namespaces")
    if namespaces is None:
        add(NOT_COLLECTED)
        add("")
    else:
        add(f"**{len(namespaces)} namespaces.**")
        add("")
        add(
            md_table(
                ["Namespace", "PSA enforce", "PSA audit"],
                [[n["name"], n["psa_enforce"], n["psa_audit"]] for n in namespaces],
            )
        )
        unlabelled = [n["name"] for n in namespaces if n["psa_enforce"] == "-"]
        if unlabelled:
            add(
                f"**{len(unlabelled)} namespaces carry no explicit PSA enforce label** and"
                " inherit the cluster default (`baseline`): "
                + ", ".join(f"`{n}`" for n in unlabelled)
                + ". Gap GAP-M3, owned by WP4."
            )
            add("")

    # 7. Persistent data
    add("## 7. Persistent data assets")
    add("")
    pvcs = live.get("pvcs")
    if pvcs is None:
        add(NOT_COLLECTED)
        add("")
    else:
        add(
            f"**{len(pvcs)} PersistentVolumeClaims.** Each is in scope for the backup"
            " and retention obligations in `business-continuity-plan.md` and"
            " `logging-and-retention-policy.md`."
        )
        add("")
        add(
            md_table(
                ["Namespace", "PVC", "StorageClass", "Size", "Phase"],
                [[p["namespace"], p["name"], p["class"], p["size"], p["phase"]] for p in pvcs],
            )
        )

    # 8. External data custodians
    add("## 8. External data custodians declared in `platform.yaml`")
    add("")
    nas_rows = []
    for provider, cfg in sorted((platform.get("nas_providers") or {}).items()):
        cfg = cfg or {}
        nas_rows.append(
            [
                provider,
                "yes" if cfg.get("enabled") else "no",
                cfg.get("host", UNKNOWN),
                "SMB" if cfg.get("smb_enabled") else "",
                "NFS" if cfg.get("nfs_enabled") else "",
                ", ".join(cfg.get("managed_shares") or []),
            ]
        )
    add(
        md_table(
            ["Provider", "Enabled", "Host", "SMB", "NFS", "Managed shares"],
            nas_rows,
        )
    )
    persistence = ((platform.get("persistence") or {}).get("truenas") or {})
    add(
        f"Longhorn volume backup target (declared): `nfs://{persistence.get('nfs_ip', UNKNOWN)}"
        f"{persistence.get('nfs_path', UNKNOWN)}`, enabled="
        f"{persistence.get('enabled', UNKNOWN)}. Verify the LIVE value — they have"
        " drifted before (GAP-C2): `kubectl get backuptarget -n longhorn-system"
        " -o jsonpath='{.items[*].spec.backupTargetURL}'`."
    )
    add("")
    add("Commercial/contractual detail for these and all other third parties is in")
    add("`vendor-register.md`.")
    add("")

    add("---")
    add("")
    add("## Classification")
    add("")
    add(
        "This platform uses three classes (see `information-security-policy.md` §6):"
    )
    add("")
    add(
        md_table(
            ["Class", "Meaning", "Examples in this inventory"],
            [
                [
                    "Secret",
                    "Compromise grants access to other systems",
                    "OpenBao contents, Kubernetes Secrets, kubeconfig, Talos PKI, SOPS/age keys, Proxmox API tokens",
                ],
                [
                    "Personal",
                    "Identifies a natural person (GDPR in scope)",
                    "`users.yaml`, Authentik user table, Nextcloud data, Jellyfin profiles, WordPress site users, mail addresses",
                ],
                [
                    "Operational",
                    "Everything else the platform runs on",
                    "Manifests, container images, metrics, logs, this inventory",
                ],
            ],
        )
    )
    add(
        "No secret values appear in this file or anywhere else in"
        " `docs/compliance/`. Secrets live only in OpenBao and, for IaC, in"
        " SOPS/age-encrypted `envs/*/secrets.sops.yaml`."
    )
    add("")
    return "\n".join(doc) + "\n"


# ── entrypoint ───────────────────────────────────────────────────────────────


def main() -> int:
    default_root = pathlib.Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--repo-root",
        type=pathlib.Path,
        default=default_root,
        help=f"repository root containing platform.yaml (default: {default_root})",
    )
    parser.add_argument(
        "--out",
        type=pathlib.Path,
        default=None,
        help="output path (default: <repo-root>/docs/compliance/asset-inventory.md)",
    )
    parser.add_argument("--stdout", action="store_true", help="print instead of writing")
    parser.add_argument(
        "--no-cluster",
        action="store_true",
        help="skip all live kubectl collection (offline/CI mode)",
    )
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    platform = collect_platform(repo_root)

    live: dict = {"_errors": {}}
    if args.no_cluster:
        live["_errors"]["live cluster"] = "--no-cluster requested"
    else:
        for key, label, fn in (
            ("nodes", "kubectl get nodes", collect_nodes),
            ("apps", "kubectl get applications.argoproj.io -A", collect_argocd_apps),
            ("namespaces", "kubectl get ns", collect_namespaces),
            ("pvcs", "kubectl get pvc -A", collect_data_stores),
        ):
            try:
                live[key] = fn()
            except CollectionError as exc:
                live["_errors"][label] = str(exc)
                sys.stderr.write(f"warning: {label}: {exc}\n")

    vms = collect_hypervisor_vms(repo_root)
    generated_at = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    rendered = render(platform, live, vms, generated_at)

    if args.stdout:
        sys.stdout.write(rendered)
        return 0

    out_path = args.out or (repo_root / "docs" / "compliance" / "asset-inventory.md")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(rendered, encoding="utf-8")
    sys.stderr.write(f"wrote {out_path} ({len(rendered.splitlines())} lines)\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
