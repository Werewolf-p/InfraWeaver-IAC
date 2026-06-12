# N8N Workflow Blueprints

Infrastructure-as-Code approach for defining, managing, and deploying n8n workflow blueprints to the automation platform.

## Structure

```
kubernetes/n8n-blueprints/
├── README.md                 # This file
├── values.yaml              # Helm-like values for blueprint parameterization
├── kustomization.yaml       # Kustomize overlay
├── templates/               # Blueprint JSON definitions
│   ├── cluster-health-monitor.json
│   ├── problem-detector.json
│   ├── auto-fix-workflow.json
│   ├── time-range-check.json
│   └── git-auto-commit.json
└── scripts/
    ├── deploy-blueprints.sh       # Deploy blueprints to running n8n
    ├── export-blueprints.sh       # Export from n8n for versioning
    └── validate-blueprints.sh     # JSON schema validation
```

## Blueprint Templates

Each blueprint is defined as a JSON workflow file (n8n native format):

- **cluster-health-monitor.json** — 24/7 health monitoring with 2-hour stability tracking
- **problem-detector.json** — Automated log scanning and error detection
- **auto-fix-workflow.json** — Remediation with approval gates
- **time-range-check.json** — Custom time-scoped monitoring
- **git-auto-commit.json** — Automatic commit workflow fixes to main branch

## Deployment

### Option 1: API Import (Manual)
```bash
./scripts/deploy-blueprints.sh --n8n-url https://n8n.${BASE_DOMAIN} \
  --n8n-token <admin-token> \
  --blueprints templates/
```

### Option 2: GitOps (Automatic)
ArgoCD can be configured to sync blueprints from this directory and trigger n8n API imports.

### Option 3: Helm/Kustomize
Use Kustomization overlay to manage blueprints as ConfigMaps, then a Kubernetes CronJob runs the deploy script.

## Versioning

Blueprints are stored in Git:
- YAML/JSON source files are versioned in `kubernetes/n8n-blueprints/templates/`
- Updates to blueprints trigger GitHub Actions workflow to validate and deploy
- Export workflows from n8n periodically to ensure Git is authoritative source

## Validation

```bash
# Validate all blueprints before commit
./scripts/validate-blueprints.sh templates/

# Check N8N API connectivity
curl -H "X-N8N-API-KEY: <token>" https://n8n.${BASE_DOMAIN}/api/v1/health
```

## Environment Variables

Define in `values.yaml` or `.env`:
- `N8N_URL` — n8n instance URL
- `N8N_ADMIN_TOKEN` — API token from n8n admin
- `PROXMOX_API_URL` — Proxmox API endpoint
- `PROXMOX_TOKEN_ID` — PVE token
- `GITHUB_TOKEN` — GitHub API token
- `SSH_PRIVATE_KEY` — SSH key for remote execution

## CI/CD Integration

GitHub Actions workflow (`.github/workflows/n8n-blueprints.yml`):
1. On PR: Validate blueprint JSON schema
2. On merge to main: Deploy blueprints to n8n
3. On manual trigger: Export current blueprints from n8n to Git

## Backup & Recovery

Export all workflows from n8n:
```bash
./scripts/export-blueprints.sh --n8n-url https://n8n.${BASE_DOMAIN} \
  --n8n-token <admin-token> \
  --output templates/
```

Restore from Git:
```bash
./scripts/deploy-blueprints.sh --n8n-url https://n8n.${BASE_DOMAIN} \
  --n8n-token <admin-token> \
  --blueprints templates/
```

---

**Last Updated:** 2026-05-26
