# InfraWeaver Init — Manual Steps

Things that cannot be automated and must be done by hand before or after running the init wizard.

---

## Before First Deploy

### 1. GitHub Repository (optional — for GitHub sync)
GitHub does not have a public API for creating repositories without authentication.
If you want GitHub as an upstream mirror of your Onedev repo:
- Create a repository at github.com with the same name as this platform
- Generate a Personal Access Token (classic) with `repo` scope
- Add the token as `PLATFORM_GITHUB_PAT` in your `.env`
- The bootstrap script will mirror commits from Onedev → GitHub automatically

If you skip this, everything still works — Onedev acts as the sole git remote.

### 2. Cloudflare API Token + Zone ID
Required for external DNS (ExternalDNS operator) and TLS certificates (cert-manager).
- Log in to dash.cloudflare.com → Profile → API Tokens
- Create a token with `Zone:DNS:Edit` permission scoped to your domain zone
- Set `CLOUDFLARE_API_TOKEN` in `.env`
- Your Zone ID is on the Overview page of your domain — set `CLOUDFLARE_ZONE_ID` in `.env`

### 3. SMTP Credentials
Required for platform notification emails (Authentik, Onedev, alerts).
- Obtain from your email provider (Gmail, Fastmail, Sendgrid, etc.)
- Set `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_TO` in `.env`

### 4. Proxmox API Token
Required for OpenTofu to provision Talos VMs.
- In the Proxmox web UI: Datacenter → Permissions → API Tokens → Add
- Create a token for user `root@pam` with PVEVMAdmin + PVEDatastoreAdmin roles
- Disable "Privilege Separation" so the token inherits root permissions
- Set `PROXMOX_API_TOKEN` in `.env` as `user@realm!tokenid=secret`

### 5. GitHub Runner Registration Token (if using self-hosted GitHub Actions runners)
- Go to your GitHub repository → Settings → Actions → Runners → New self-hosted runner
- Copy the registration token (valid for 1 hour)
- Set `RUNNER_REGISTRATION_TOKEN` in `.env` before running the deploy
- After the runner registers, the token is no longer needed

---

## After First Deploy

### 7. Authentik SSO — Set Client Auth Method for Onedev
The Onedev OIDC provider in Authentik must use `client_secret_post` auth method (Onedev does not support `client_secret_basic`):
- Go to Authentik Admin UI → Applications → Providers
- Find the Onedev provider → Edit → Advanced protocol settings
- Set **Client authentication method** to `client_secret_post`
- Save and test SSO login

### 8. MetalLB Control Plane VIP
If you reboot the primary control plane node (`CP1`), the MetalLB VIP `10.10.0.200` may not re-announce until a second node becomes leader. To make it resilient across CP1 reboots:
- After deploy, verify the VIP is in the MetalLB address pool: `kubernetes/core/metallb/manifests/`
- Update your kubeconfig server URL to point to the VIP, not a node IP

### 9. Storage Provisioning
Longhorn data is stored on node-local disks and is NOT included in IaC snapshots. After a full redeploy:
- Storage volumes start empty
- Game server data, Onedev repositories, TrueNAS-backed PVCs must be restored from backups
- Configure Longhorn backup target (S3 or NFS) in the Longhorn UI before storing important data

---

## Not Automated (by Design)

| Item | Why |
|---|---|
| GitHub repo creation | Requires interactive OAuth — no headless API |
| SSH key pair generation | User-specific; generate once with `ssh-keygen -t ed25519` |
| Cloudflare Zone ID | Read from Cloudflare dashboard — tied to your domain registration |
| SMTP provider credentials | Come from external email provider accounts |
| Proxmox API token | Created in Proxmox web UI; cannot be scripted from outside |
| GitHub runner tokens | Expire after 1 hour; regenerate each deploy |
