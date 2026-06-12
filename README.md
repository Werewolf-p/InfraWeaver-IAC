# InfraWeaver Infrastructure

**This is the Infrastructure-as-Code (IaC) repo.** ArgoCD watches this repo exclusively.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     GitHub (Public/Code)                          │
│  Repo: InfraWeaver-platform                                      │
│  Contains: App source (Next.js, Hono API), docs, CI/CD           │
│  Purpose: Code changes, PRs, image builds                        │
└───────────────────────────┬─────────────────────────────────────┘
                            │ CI builds images →
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     OneDev (Private/Infra)                        │
│  Repo: InfraWeaver-infra                                         │
│  Contains: kubernetes/, ansible/, terraform/, scripts/            │
│  Purpose: ArgoCD source, cluster configs, deploy manifests        │
│  ⚠️  ArgoCD watches THIS repo with prune:true                    │
└───────────────────────────┬─────────────────────────────────────┘
                            │ ArgoCD syncs →
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                            │
└─────────────────────────────────────────────────────────────────┘
```

## Rules

1. **NEVER force-push to this repo** — ArgoCD will delete everything
2. **Only infra changes go here** — app code stays on GitHub
3. **n8n automation** pushes config changes here (image tags, replicas, etc.)
4. **Manual kubectl apply** for emergencies only; always commit here first

## Structure

```
kubernetes/
├── bootstrap/     # ArgoCD Application definitions
├── core/          # Cluster infrastructure (Traefik, cert-manager, MetalLB, etc.)
├── catalog/       # Application deployments (console, API, OneDev, game-hub)
├── platform/      # Platform helm releases (Authentik, monitoring)
└── apps/          # Lightweight app manifests
ansible/           # Playbooks for bare-metal + VM config
terraform/         # OpenTofu for Proxmox VMs, DNS, cloud resources
scripts/           # Deploy/init helper scripts
envs/              # Environment-specific overrides
```

## n8n Integration

n8n dispatches coding agents that:
- Push **code** changes → GitHub (`InfraWeaver-platform`)
- Push **config** changes → OneDev (`InfraWeaver-infra`)

Env vars needed in n8n:
- `CODING_AGENT_DISPATCH_URL=http://10.10.0.108:9876`
- `GITHUB_TOKEN` — for code repo pushes
- `ONEDEV_INFRA_URL=http://onedev.onedev.svc.cluster.local/InfraWeaver-infra`
- `ONEDEV_TOKEN` — OneDev API access token

---

## Forking InfraWeaver (open-source model)

InfraWeaver ships **capabilities + catalog definitions**; **you own your desired
state**. Every deployment-specific value is a `${PLACEHOLDER}` filled from your
own `.env` / `envs/<env>/` files — so you can pull upstream updates without
merge conflicts.

### 1. Fork & configure

```bash
git clone https://github.com/your-org/your-infra-repo && cd your-infra-repo
cp .env.example .env          # or just run the wizard:
bash scripts/setup.sh         # prompts for domain, repos, registry, email, DNS
```

The handful of files **you** own (everything else stays upstream):

| File | What you set |
|------|--------------|
| `.env` (gitignored) | the single source of truth — domain, repos, registry, nodes, secrets |
| `envs/<env>/cluster.yaml` | Talos/Proxmox node topology — per-node `role: control\|worker\|hybrid` (see [docs/cluster-builder.md](docs/cluster-builder.md)) |
| `envs/<env>/terraform.tfvars` | terraform cluster identity + SSH keys |
| `platform.yaml` | which catalog apps / platform components are enabled |
| `kubernetes/**/overlays/local/` (gitignored) | your personal routes/overrides |

Key variables (see `.env.example` for the full list):

- `BASE_DOMAIN` — apps are served at `*.${BASE_DOMAIN}` and `*.int.${BASE_DOMAIN}`
- `INFRA_REPO_URL` — the IaC repo ArgoCD watches (your fork of this repo)
- `GIT_REPO_URL` / `GITHUB_REPO` — your application/code repo (console + API source)
- `IMAGE_REGISTRY` — where your built images live (e.g. `ghcr.io/your-org`)
- `ADMIN_EMAIL`, `ADMIN_USERNAME`, `K8S_CLUSTER_NAME`

### 2. Substitute placeholders

```bash
bash scripts/generate-from-env.sh   # fills ${VARS} in kubernetes/, envs/, users.yaml
```

> ⚠️ Run this **before** ArgoCD bootstrap / `tofu apply`. The committed template
> intentionally contains `${PLACEHOLDERS}`, not real values — they are only
> resolved into the copy ArgoCD watches. (The repo's pre-push guard also blocks
> pushing raw `kubernetes/**` config upstream.)

### 3. Secrets

Secrets are **never** committed: they live in `.env` (gitignored) and are seeded
into **OpenBao** via `scripts/seed-openbao-*.sh`, then surfaced to workloads as
**ExternalSecrets** (ESO). The `scripts/validate-iac.sh` secret-leak gate fails
the build if a raw `Secret` with a real value is ever added.

### 4. Pull upstream updates

Because your config lives in `.env` / `envs/` / `overlays/local/` and upstream
ships only placeholders, a `git pull` (or merge from upstream) rarely conflicts.
Re-run `scripts/generate-from-env.sh` after pulling to re-substitute.

### The one fixed value

Exactly **one** value in InfraWeaver is intentionally **not** configurable: the
**user-feedback submission URL**. The console's `POST /api/feedback`
(`apps/infraweaver-console/src/app/api/feedback/route.ts`) hardcodes:

```
FEEDBACK_URL = "https://infraweaver.example.com/api/feedback"
```

Every forked deployment still stores feedback locally for its own admins, **and**
fire-and-forwards a sanitized copy to this canonical InfraWeaver endpoint, so the
maintainers can keep improving the platform for all forks. It is a hardcoded
constant with **no `process.env` override** by design (a loop-guard header
prevents the canonical deployment from re-forwarding to itself). This is the sole
deliberate exception to "everything is a variable."
