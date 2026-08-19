#!/usr/bin/env python3
"""validate-gitops-coverage.py — "committed but never deployed" gate.

This repository's signature failure mode is a directory of perfectly valid
Kubernetes manifests that NO ArgoCD Application renders. The manifests are in
git, they pass `kubeconform`, they show up in code review, `git log` says they
shipped — and the cluster has never seen them. Found so far:

  * kubernetes/core/rbac/                       (fixed 2026-08-15; a
    cluster-admin binding stayed live because the replacement was never applied)
  * kubernetes/core/etcd-maintenance/           (in git since ~2026-08-07;
    `kubectl get clusterrole etcd-metrics-logger` → NotFound)
  * kubernetes/catalog/game-hub/manifests/      (live, but owned by nobody:
    edits to the ResourceQuota would never have reached the cluster)
  * kubernetes/platform/minio-velero/manifests/ (live, but owned by nobody —
    and Velero's only BackupStorageLocation depends on it)

Every one of those was invisible because nothing checked. This is that check.

────────────────────────────────────────────────────────────────────────────────
HOW COVERAGE IS DECIDED

A directory "contains manifests" when it holds at least one *.yaml/*.yml file
with a top-level `apiVersion:` and `kind:` — excluding the files that are
*inputs* to a renderer rather than manifests themselves (values.yaml,
application.yaml, catalog.yaml, kustomization.yaml).

A directory is COVERED when any of these hold:

  1. An ArgoCD Application declared in this repo targets it.
       - `spec.source.plugin` (the envsubst CMP) renders the WHOLE SUBTREE: the
         plugin's generate command is `find . -name '*.yaml' -type f`. This is
         why kubernetes/platform/authentik/manifests/blueprints/ is fine
         despite the Application naming only the parent.
       - `spec.source.directory.recurse: true` also covers the subtree.
       - anything else covers ONLY the directory named, never a subdirectory.
         This is the trap: eight tier Applications point at kubernetes/<tier>
         with no recurse and therefore render exactly nothing.
  2. It is reachable through a `kustomization.yaml` resource graph rooted at a
     covered directory (the base/ + overlays/prod layout).
  3. It lives under kubernetes/catalog/<app>/ and <app>/catalog.yaml exists —
     catalog apps are installed on demand, and their bootstrap Application in
     kubernetes/bootstrap/catalog-*.yaml is hand-maintained. (A generator,
     scripts/sync-catalog.sh, used to write those files; it was deleted
     2026-08-18 as dead-but-armed code.)
  4. It carries an explicit dormant marker (see below).

────────────────────────────────────────────────────────────────────────────────
DECLARING SOMETHING DORMANT

Parked-on-purpose is a legitimate answer; "we forgot" is not. The difference has
to be written down where the manifests are, not in a wiki. Put this line in any
*.yaml / *.yml / *.md file in the directory:

    # gitops-coverage: dormant - <why, and what would turn it on>

The reason is mandatory and is printed by this gate, so `--list` doubles as the
inventory of everything the platform is deliberately not running.

A dormant marker on a directory that IS covered is also an error: it means the
note went stale when the Application was wired, and a stale note is how the next
person gets misled.

Usage:  python3 scripts/validate-gitops-coverage.py [--repo-root PATH] [--list]
Exit 0 clean, 1 on any uncovered/mis-marked directory.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - CI installs PyYAML explicitly
    sys.stderr.write("validate-gitops-coverage: PyYAML is required\n")
    sys.exit(1)

# Files that live next to manifests but are renderer INPUTS, not manifests.
RENDERER_INPUTS = {"values.yaml", "application.yaml", "catalog.yaml", "kustomization.yaml"}

# kubernetes/<tier> top levels are rendered by the `platform` ApplicationSet that
# OpenTofu creates (terraform/modules/platform-bootstrap/main.tf): a git
# *directory* generator matching `kubernetes/*`, one Application per first-level
# subdirectory, `path = {{path}}`, no `directory.recurse`. That ApplicationSet is
# not a file in this repo, so it cannot be discovered by scanning — but it is the
# reason kubernetes/bootstrap/ is legitimately covered while
# kubernetes/<tier>/<app>/ never is.
TIER_GENERATOR = "terraform/modules/platform-bootstrap/main.tf (`platform` ApplicationSet)"

DORMANT_RE = re.compile(r"#\s*gitops-coverage:\s*dormant\s*[-:—]\s*(?P<reason>.+)")
MANIFEST_RE_KIND = re.compile(r"^kind:\s*\S", re.M)
MANIFEST_RE_API = re.compile(r"^apiVersion:\s*\S", re.M)


def read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def is_manifest_file(path: str) -> bool:
    text = read(path)
    return bool(MANIFEST_RE_KIND.search(text) and MANIFEST_RE_API.search(text))


def yaml_docs(path: str):
    try:
        for doc in yaml.safe_load_all(read(path)):
            if isinstance(doc, dict):
                yield doc
    except yaml.YAMLError:
        return


# ── discovery: directories holding manifests ─────────────────────────────────
def manifest_dirs(root: str, scan_root: str) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, scan_root)):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        rel = os.path.relpath(dirpath, root)
        files = [
            f
            for f in sorted(filenames)
            if f.endswith((".yaml", ".yml"))
            and f not in RENDERER_INPUTS
            and is_manifest_file(os.path.join(dirpath, f))
        ]
        if files:
            found[rel] = files
    return found


# ── discovery: what the Applications in this repo actually render ────────────
def _source_paths(spec: dict) -> list[dict]:
    out = []
    if isinstance(spec.get("source"), dict):
        out.append(spec["source"])
    out.extend(src for src in spec.get("sources") or [] if isinstance(src, dict))
    return out


def covered_paths(root: str) -> tuple[set[str], set[str]]:
    """Return (exact_dirs, subtree_roots) that some Application renders."""
    exact: set[str] = set()
    subtree: set[str] = set()

    # The terraform-generated tier ApplicationSet: kubernetes/* top levels only.
    for entry in sorted(os.listdir(os.path.join(root, "kubernetes"))):
        if os.path.isdir(os.path.join(root, "kubernetes", entry)):
            exact.add(f"kubernetes/{entry}")

    for dirpath, dirnames, filenames in os.walk(os.path.join(root, "kubernetes")):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            # `.disabled` files are deliberately inert — an Application that is
            # not applied covers nothing, which is exactly the bug this gate
            # exists to surface (app-minio-velero.yaml.disabled sat next to a
            # running Deployment for weeks).
            if not name.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, name)
            for doc in yaml_docs(path):
                kind = doc.get("kind")
                if kind == "Application":
                    spec = doc.get("spec") or {}
                    targets = _source_paths(spec)
                elif kind == "ApplicationSet":
                    spec = ((doc.get("spec") or {}).get("template") or {}).get("spec") or {}
                    targets = _source_paths(spec)
                else:
                    continue
                for src in targets:
                    p = src.get("path")
                    if not isinstance(p, str) or "{{" in p or not p.startswith("kubernetes/"):
                        continue
                    p = p.rstrip("/")
                    directory = src.get("directory") or {}
                    if src.get("plugin") or directory.get("recurse") is True:
                        subtree.add(p)
                    else:
                        exact.add(p)
    return exact, subtree


def kustomize_reachable(root: str, seeds: set[str]) -> set[str]:
    """Follow kustomization.yaml `resources:` from every seed directory."""
    seen: set[str] = set()
    queue = list(seeds)
    while queue:
        rel = queue.pop()
        if rel in seen:
            continue
        seen.add(rel)
        kpath = os.path.join(root, rel, "kustomization.yaml")
        if not os.path.isfile(kpath):
            continue
        for doc in yaml_docs(kpath):
            for res in doc.get("resources") or []:
                if not isinstance(res, str) or "://" in res:
                    continue
                target = os.path.normpath(os.path.join(rel, res))
                if os.path.isdir(os.path.join(root, target)):
                    queue.append(target)
                else:
                    parent = os.path.dirname(target)
                    if parent:
                        seen.add(parent)
    return seen


# ── discovery: dormant markers ────────────────────────────────────────────────
def dormant_reason(root: str, rel: str) -> str | None:
    directory = os.path.join(root, rel)
    for name in sorted(os.listdir(directory)):
        if not name.endswith((".yaml", ".yml", ".md")):
            continue
        full = os.path.join(directory, name)
        if not os.path.isfile(full):
            continue
        match = DORMANT_RE.search(read(full))
        if match:
            return match.group("reason").strip()
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("--list", action="store_true", help="print the full coverage table, not just failures")
    args = ap.parse_args()
    root = os.path.abspath(args.repo_root)

    dirs = manifest_dirs(root, "kubernetes")
    exact, subtree = covered_paths(root)
    kust = kustomize_reachable(root, exact | subtree)

    def is_covered(rel: str) -> str | None:
        if rel in exact:
            return "application"
        for base in subtree:
            if rel == base or rel.startswith(base + "/"):
                return "application (subtree)"
        if rel in kust:
            return "kustomize"
        parts = rel.split("/")
        if (
            len(parts) >= 3
            and parts[0] == "kubernetes"
            and parts[1] == "catalog"
            and os.path.isfile(os.path.join(root, "kubernetes", "catalog", parts[2], "catalog.yaml"))
        ):
            return "catalog registry (on-demand install)"
        return None

    uncovered: list[tuple[str, list[str]]] = []
    dormant: list[tuple[str, str]] = []
    stale: list[tuple[str, str, str]] = []
    covered: list[tuple[str, str]] = []

    for rel in sorted(dirs):
        how = is_covered(rel)
        reason = dormant_reason(root, rel)
        if how and reason:
            stale.append((rel, how, reason))
        elif how:
            covered.append((rel, how))
        elif reason:
            dormant.append((rel, reason))
        else:
            uncovered.append((rel, dirs[rel]))

    if args.list:
        print(f"==> tier top levels rendered by {TIER_GENERATOR}")
        print(f"==> {len(covered)} covered, {len(dormant)} dormant, {len(uncovered)} uncovered\n")
        for rel, how in covered:
            print(f"  ok       {rel}  [{how}]")
        for rel, reason in dormant:
            print(f"  dormant  {rel}  — {reason}")

    rc = 0
    if uncovered:
        rc = 1
        print("\n❌ manifests in git that NO ArgoCD Application renders:\n")
        for rel, files in uncovered:
            print(f"  {rel}/")
            for f in files:
                print(f"      {f}")
        print(
            "\n  Fix one of two ways:\n"
            "    • wire it — add an Application under kubernetes/bootstrap/ (copy\n"
            "      app-velero-manifests.yaml), or add `directory: {recurse: true}`\n"
            "      / the envsubst plugin to the Application that already names the\n"
            "      parent directory;\n"
            "    • park it — add `# gitops-coverage: dormant - <why>` to a file in\n"
            "      the directory, saying what would turn it on.\n"
        )
    if stale:
        rc = 1
        print("\n❌ dormant marker on a directory that IS rendered (stale note):\n")
        for rel, how, reason in stale:
            print(f"  {rel}/  covered by {how}, but still says: {reason}")
        print("\n  Delete the marker — it is now describing something untrue.\n")

    if rc == 0:
        print(
            f"✅ gitops-coverage: {len(covered)} manifest directories rendered, "
            f"{len(dormant)} declared dormant, 0 orphaned"
        )
    return rc


if __name__ == "__main__":
    sys.exit(main())
