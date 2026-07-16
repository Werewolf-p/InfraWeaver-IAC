# InfraWeaver GitOps / IaC Operating Model

How infrastructure changes are authored, validated, shipped, and reconciled — the
"platform runbook." Goal: **fully declarative (ArgoCD reconciles git → cluster)**,
**no secrets or local values in git**, yet **easy for a developer to update**.
Modeled on how larger orgs run GitOps (separation of config from code, PR-gated
changes, secrets in a vault, env params in overlays, automated image promotion).

---

## 0. Forking & placeholders (open-source model)

InfraWeaver is a **forkable template**: committed config uses `${PLACEHOLDER}`
variables, never real deployment values. A forker fills `.env` (gitignored) — or
runs `scripts/setup.sh` — then `scripts/generate-from-env.sh` substitutes the
placeholders into `kubernetes/`, `envs/` and `users.yaml` before bootstrap. This
keeps every deployment-specific value (domain, repo URLs, image registry, node
topology, admin email) out of upstream and lets forks pull updates without
conflicts. The **only** hardcoded value is the user-feedback URL (see README,
"The one fixed value"). Full guide: README → "Forking InfraWeaver".

> **Target evolution:** move placeholder resolution from the provision-time
> `generate-from-env.sh` step to **sync-time inside ArgoCD** via a Config
> Management Plugin, so ArgoCD watches this repo with `${}` intact. Design:
> [`gitops-cmp-substitution.md`](./gitops-cmp-substitution.md).

---

## 1. Principles

1. **Git is the source of truth.** The cluster is a projection of `main`. Never
   `kubectl edit` live objects that ArgoCD owns — `selfHeal` will revert you.
2. **Config is separated from code.** App source builds an image; *what is
   deployed* lives in this infra repo.
3. **Secrets never live in git.** Git holds *references*; real values live in
   OpenBao and are projected by External Secrets Operator (ESO).
4. **Changes are gated, not trusted.** A PR must pass CI (`validate-iac`) before
   it can reach `main`. The client-side `pre-push` hook is a fast local pre-check,
   not the real gate.
5. **One way to validate.** The same `scripts/validate-iac.sh` runs locally and
   in CI, so "passes on my laptop" == "passes the pipeline."

---

## 2. Repository topology

| Repo | Owns | Consumed by |
|------|------|-------------|
| `InfraWeaver-platform` | application source code | image build → registry |
| `InfraWeaver-infra` (this) | all declarative infra/config | ArgoCD |

> The local `platform/kubernetes → infra/kubernetes` symlink is a *viewing*
> convenience only; nothing is committed through it. Mental model:
> **platform = code, infra = config.**

**Current split to rationalize:** some ArgoCD Applications source from GitHub
(`catalog-infraweaver-*`, authentik) and some ApplicationSets source from OneDev
(`platform/`, `core/`, `monitoring/`). Target: pick **one** authoritative remote
for ArgoCD (recommended: GitHub `main`, mirror to OneDev) so there is a single
reconcile source. Tracked as migration item M4.

---

## 3. Config layering (the param model)

Kustomize `base/` + `overlays/`. Reference implementation:
`kubernetes/catalog/infraweaver-console/` (see its README).

```
<app>/
  base/                # environment-agnostic manifests — change rarely
  overlays/
    prod/              # COMMITTED params for the live cluster (image tag, scaling)
    local/             # GITIGNORED — a dev's personal override, never cluster truth
```

- **Shared/prod params** (image tag, replicas bounds, hostnames) → `overlays/prod/`,
  committed. This is the only place a normal change touches.
- **Local dev params** → `overlays/local/` (gitignored) or `*.local.yaml`. A dev
  iterates with `kubectl apply -k overlays/local` or a throwaway ArgoCD app, and
  nothing leaks into cluster truth. **This is the answer to "local values stay
  local but it's still IaC."**
- Helm-based apps (`platform/`, `core/`) already follow the equivalent pattern via
  `$values/.../values.yaml`.

---

## 4. Secrets model (no secrets in git)

**Mechanism (already in place):** OpenBao (vault) + External Secrets Operator.
Git contains an `ExternalSecret` that *references* a key; ESO pulls the value and
creates the real `Secret` in-cluster. 37 ExternalSecrets are in use.

**Rule enforced by `validate-iac.sh` (§3 secret-leak gate):** a PR that adds a
raw `kind: Secret` with a real value fails. Existing offenders are *baselined*
(ratchet) so the gate is enforceable today while we migrate them.

**Known offenders to migrate (remove from baseline as fixed):**

| File | Secret | Action |
|------|--------|--------|
| `catalog/onedev/manifests/resources.yaml` | `onedev-db-secret` (real DB password) | → ExternalSecret from OpenBao (or generated Secret) — **P1** |
| `catalog/calibre-web/manifests/secrets.yaml` | `oauthlib-relax-token-scope-secret` | non-sensitive flag → **ConfigMap** (not a Secret) |
| `catalog/{vaultwarden,bookstack}/manifests/secrets.yaml` | placeholder `change-me` | → ExternalSecret; never commit the real value |

---

## 5. The change flow (target)

```
 dev edits overlays/prod (or base)         ┐
   └─ scripts/validate-iac.sh (local)      │  fast local pre-check
 git push feature branch → open PR         │
   └─ CI: validate-iac (render+schema+secret gate)   ← REQUIRED check
 PR review + green CI → merge to main (protected)    ← the real gate
   └─ ArgoCD detects main, syncs cluster   ┘  reconcile
```

**To adopt (M1):** enable GitHub **branch protection** on `main` — require the
`validate-iac` check + 1 review, disallow direct pushes. This replaces "push to
main + client-side hook" (a band-aid) with the standard server-side gate. The
`pre-push` hook stays as a courtesy local check.

**Image bumps** are the exception that may fast-path to `main` (small, frequent):
they only change `image:`/`newTag:` lines, which the `pre-push` guard and CI both
recognize. Performed by the feedback dispatch (`/approve`) and reversible
(`/rollback`).

---

## 6. Image automation

- App built externally → pushed to `registry.int.${BASE_DOMAIN}` / ghcr.io.
- The pin (`overlays/prod/kustomization.yaml` `newTag:`) is bumped by
  `infraweaver-dispatch` on `/approve` and reverted on `/rollback`.
- **Optional hardening (M3):** re-enable ArgoCD Image Updater (currently
  `*.disabled`) with **git write-back** so tag bumps are committed automatically
  with an audit trail, removing the bespoke `sed` path.

---

## 7. Drift & selfHeal

- ArgoCD `selfHeal: true` reverts out-of-band cluster edits — intended.
- **Do not declare a field two owners want.** Classic trap: `spec.replicas` in a
  Deployment that also has an HPA → selfHeal ↔ HPA war. Fix: omit `replicas` from
  the manifest (HPA owns it). Applied to the console; apply to every HPA'd app.
- For imperatively-managed workloads (e.g. game servers), keep them out of git
  ownership entirely rather than fighting selfHeal.

---

## 8. Migration plan (status)

| # | Item | Status |
|---|------|--------|
| M0 | Console → base/overlays + param seam + dispatch/guard/sync wiring | **done (uncommitted)** |
| M1 | Branch protection on `main` (require `validate-iac` check + 1 review; `enforce_admins=false` so the dispatch admin token still direct-pushes image bumps) | **APPLIED on GitHub.** Required check turns green once the workflow lands on `main`. |
| M2 | api + node → base/overlays (api drops `replicas`→HPA; node keeps `replicas`, no HPA) | **done (uncommitted)** |
| M3 | Image automation | **Decision: KEEP dispatch `/approve` git-write-back** (it commits+pushes the pin = GitOps-correct, and is *approve-gated*). ArgoCD Image Updater **intentionally not adopted** — it does continuous *ungated* auto-deploy, conflicting with the approve-gated model. |
| M4 | Single authoritative ArgoCD remote (GitHub vs OneDev) | **Staged — not a safe quick repoint.** GitHub infra has only 2 `platform/*/application.yaml` vs many served from OneDev, so repointing now would drop live apps. Steps: (1) copy missing `platform/`+`monitoring/` `application.yaml`+`values.yaml` from the OneDev platform repo into this repo, (2) `validate-iac`, (3) repoint the 4 appsets' `repoURL` OneDev→GitHub, (4) confirm generated app count unchanged, (5) keep OneDev as a read mirror. |
| M5 | Raw Secrets → ESO / inline | **done:** `onedev-db-secret` → ExternalSecret (OpenBao `secret/platform/onedev` seeded with the exact existing creds, so postgres is unaffected on restart); calibre `OAUTHLIB_RELAX_TOKEN_SCOPE` inlined as a literal; secret-leak baseline now empty. |

---

## 9. Quick reference

```sh
# Validate everything the way CI does:
scripts/validate-iac.sh             # render + schema + secret-leak gate
scripts/validate-netpol-ports.sh    # NetworkPolicy ports must be POD ports, not Service ports

# Render what ArgoCD will apply for an app:
kubectl kustomize kubernetes/catalog/<app>/overlays/prod

# Iterate locally without touching cluster truth:
mkdir -p kubernetes/catalog/<app>/overlays/local   # gitignored
kubectl apply -k kubernetes/catalog/<app>/overlays/local
```
