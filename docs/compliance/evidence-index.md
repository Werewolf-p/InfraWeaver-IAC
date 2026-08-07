# Evidence Index

| | |
|---|---|
| **Document ID** | ISMS-IDX-001 |
| **Version** | 1.0 |
| **Status** | Active |
| **Compiled** | 2026-08-07 |
| **Owner** | Platform Owner |
| **Next review** | Quarterly with the access review (next: 2026-11-02) |
| **Controls** | ISO/IEC 27001:2022 cl. 7.5, 9.1, A.5.28, A.8.34 · SOC 2 CC4.1, CC4.2 |

---

## 0. How to use this index

Every command below was **executed successfully on 2026-08-07** while compiling
this pack. None is aspirational. Where a command demonstrates a control
*failure*, that is stated in the Expected column — an index that only lists
passing evidence is a sales brochure, not an audit trail.

**Every command is read-only** (A.8.34): `kubectl get`/`--raw` GETs,
`talosctl read`/`time`, `gh api` GETs, `git log`, and read-only SQL `SELECT`s.
Nothing here mutates a production system. The asset-inventory generator enforces
this structurally — it refuses any `kubectl` verb other than `get`.

**Prerequisites**

```bash
export KUBECONFIG=/home/runner/.kube/config-platform-productie   # admin@infraweaver-prod
export TALOSCONFIG=/home/runner/.talos/config                    # for the two talosctl commands
cd <path-to>/InfraWeaver-infra              # for repo-relative commands
```

**Reading the results.** Two platform-specific traps, both learned from
incidents: `Synced` is not `Healthy`, and **`live` is not `available`**. Several
surfaces here answer `200` with an empty body plus a marker
(`X-Data-Source: unavailable`, `live: false`, `available: false`) rather than
erroring. Read the field, not the exit code.

---

## 1. Governance and documentation (A.5.1, A.5.9, A.5.37, cl. 7.5)

| Control | Artifact | Command | Expected |
|---|---|---|---|
| A.5.1 | `docs/compliance/information-security-policy.md` | `ls -1 docs/compliance/*.md` | `13` policy/record documents present |
| A.5.9 | `docs/compliance/asset-inventory.md` | `python3 docs/compliance/scripts/generate-asset-inventory.py --stdout \| head -40` | Renders a current inventory from `platform.yaml` + live cluster. **Regenerable — this is the control** |
| A.5.9 | Offline reproducibility | `python3 docs/compliance/scripts/generate-asset-inventory.py --no-cluster --stdout \| head -30` | Renders with a "Collection gaps in this run" table — a stale run is visible as stale, never silently partial |
| A.5.37 | Operating procedures | `ls -1 docs/*.md docs/security/*.md` | `11` runbooks/procedures incl. `SECURITY-REMEDIATION-RUNBOOK.md`, `gitops-operating-model.md`, `PRIVATE-PUBLIC-GITOPS-AND-DR.md` |
| cl. 9.1 | Risk register | `grep -c '^## RISK-' docs/compliance/risk-register.md` | `17` |
| cl. 6.1.3 d) | Statement of Applicability | `grep -cE '^\| A\.[5-8]\.[0-9]+ ' docs/compliance/statement-of-applicability.md` | `93` — all Annex A controls covered |

---

## 2. Compute, capacity and architecture (A.5.9, A.8.6, A.8.14, A.8.27)

| Control | Artifact | Command | Expected / actual on 2026-08-07 |
|---|---|---|---|
| A.5.9, A.8.14 | Node inventory | `kubectl get nodes -o wide` | 3 × Talos v1.13.0 / k8s v1.35.4, all `Ready`, `10.0.0.90-92` |
| A.8.27 | **Converged-node risk (RISK-01)** | `kubectl get nodes -o json \| jq -r '.items[] \| "\(.metadata.name) roles=\([.metadata.labels\|keys[]\|select(startswith("node-role"))]\|join(",")) taints=\(.spec.taints // "none")"'` | All 3 are `control-plane`; cp1/cp2 `taints=none` → workloads share the control plane. **cp3 additionally carries a live `node.kubernetes.io/memory-pressure:NoSchedule` taint (RISK-05).** Demonstrates two accepted risks, not a pass |
| A.8.6 | **Capacity starvation (RISK-05)** | `kubectl get nodes -o json \| jq -r '.items[] \| "\(.metadata.name) \(.status.capacity.memory)"'` | cp1 `24587224Ki`, cp2 `24587228Ki`, **cp3 `10161128Ki`** — cp3 is under half the others |
| A.8.6 | Hypervisor budget | `grep -A3 'talos-prod-cp' <infrastructure>/envs/productie/nodes.yaml` | `balloon_mb: 0` hard pins; the file records the 64 GiB host budget and why cp3 can be neither grown nor shrunk |
| A.8.6 | Live node pressure | `kubectl describe node talos-prod-cp3 \| grep -A6 Conditions` | **`MemoryPressure True` / `KubeletHasInsufficientMemory` as of 2026-08-07 10:45 — active, not historical.** RISK-05 |

---

## 3. Control-plane hardening (A.8.9, A.8.20, A.8.24, A.8.27)

| Control | Artifact | Command | Expected / actual |
|---|---|---|---|
| A.8.24, A.8.20 | API server flags | `kubectl get pod -n kube-system kube-apiserver-talos-prod-cp1 -o jsonpath='{.spec.containers[0].command}' \| tr ',' '\n' \| grep -E 'anonymous-auth\|audit-log-path\|encryption-provider\|profiling\|tls-min'` | **PASS** — `--anonymous-auth=false`, `--audit-log-path=/var/log/audit/kube/kube-apiserver.log`, `--encryption-provider-config=…`, `--profiling=false`, `--tls-min-version=VersionTLS12` |
| A.8.9 | **Missing kubelet CA (RISK-16)** | same command, `grep kubelet-certificate-authority` | **No output — the flag is absent.** GAP-M2, WP12 |
| A.8.9 | Kubelet hardening | `kubectl get --raw /api/v1/nodes/talos-prod-cp1/proxy/configz \| python3 -c "import sys,json;d=json.load(sys.stdin)['kubeletconfig'];print({k:d.get(k) for k in ['authentication','readOnlyPort','protectKernelDefaults','podPidsLimit','tlsMinVersion','seccompDefault','streamingConnectionIdleTimeout']})"` | anonymous auth `False`, webhook authz on, x509 clientCAFile set, `readOnlyPort: None`, `protectKernelDefaults: True`, `tlsMinVersion: VersionTLS13`, `seccompDefault: True`, `streamingConnectionIdleTimeout: 5m0s`. **`podPidsLimit: -1` — FAIL, RISK-16** |
| A.5.28, A.8.15 | Audit policy | `talosctl -n 10.0.0.90 read /system/config/kubernetes/kube-apiserver/auditpolicy.yaml` | `apiVersion: audit.k8s.io/v1`, single rule `level: Metadata`. Accepted position (GAP-L1) |
| **A.8.17** | **Clock synchronization** | `talosctl -n 10.0.0.90 time` | Node time matches `time.cloudflare.com` to within milliseconds. **PASS** |

---

## 4. Identity, authentication and access (A.5.15–A.5.18, A.8.2, A.8.3, A.8.5)

All Authentik queries read the database password *inside the pod* and never print
it. Do not copy it out.

| Control | Artifact | Command | Expected / actual |
|---|---|---|---|
| A.5.16 | Access register | `python3 -c "import yaml;d=yaml.safe_load(open('users.yaml'));[print(u, [r['roleId']+'@'+r['scope'] for r in (v.get('role_assignments') or [])]) for u,v in d['users'].items()]"` | 5 users, 9 grants, every one with `grantedBy`/`grantedAt` |
| A.5.16 | Authentik accounts | `kubectl exec -n authentik authentik-postgresql-0 -- bash -c 'PGPASSWORD="$(cat $POSTGRES_PASSWORD_FILE)" psql -U authentik -d authentik -tAF"\|" -c "SELECT username, is_active, type, coalesce(to_char(last_login,'"'"'YYYY-MM-DD'"'"'),'"'"'never'"'"') FROM authentik_core_user ORDER BY username;"'` | 5 active humans + `koen` deactivated + 2 internal principals. **Exact 1:1 with `users.yaml`** |
| A.5.18 | Group membership | same wrapper, `SELECT u.username, g.name FROM authentik_core_user u JOIN authentik_core_user_groups ug ON ug.user_id=u.id JOIN authentik_core_group g ON g.group_uuid=ug.group_id ORDER BY 1,2;` | 20 memberships. `admin` in `platform-admins` + `authentik Admins`; the other four scoped to one WordPress site or one storage share |
| **A.8.5** | **MFA enrolment (RISK-07)** | same wrapper, `SELECT 'totp', count(*) FROM authentik_stages_authenticator_totp_totpdevice UNION ALL SELECT 'webauthn', count(*) FROM authentik_stages_authenticator_webauthn_webauthndevice UNION ALL SELECT 'static', count(*) FROM authentik_stages_authenticator_static_staticdevice;` | **`totp\|0  webauthn\|0  static\|0` — ZERO second factors platform-wide. This is the definitive evidence for RISK-07 / F-09** |
| A.5.15 | **Unbound applications (F-01)** | same wrapper, `SELECT a.slug FROM authentik_core_application a WHERE NOT EXISTS (SELECT 1 FROM authentik_policies_policybinding b WHERE b.target_id = a.policybindingmodel_ptr_id) ORDER BY 1;` | **13 apps with no access policy** — incl. `proxmox`, `grafana`, `infraweaver-console`, `tradesphere`, `vaultwarden`. 6 live, 7 stale |
| A.5.15 | ArgoCD RBAC | `kubectl get cm argocd-rbac-cm -n argocd -o jsonpath='{.data.policy\.csv}'; echo` | `platform-admins → role:admin`, `platform-users → role:readonly`, default `role:readonly` |
| A.5.17 | ArgoCD local admin | `kubectl get cm argocd-cm -n argocd -o jsonpath='{.data.admin\.enabled}'; echo` | `false` — built-in admin login disabled. **PASS** |
| A.5.15 | **OIDC scope mismatch (F-04)** | `kubectl get cm argocd-cm -n argocd -o jsonpath='{.data.oidc\.config}'` | `requestedScopes: openid, profile, email` — **`groups` is not requested** while `argocd-rbac-cm` sets `scopes: "[groups]"`. Fails safe to readonly; verify |
| **A.8.2** | **Standing cluster-admin (RISK-09)** | `kubectl get clusterrolebindings -o json \| jq -r '.items[] \| select(.roleRef.name=="cluster-admin") \| "\(.metadata.name): \([.subjects[]? \| "\(.kind)/\(.namespace // "-")/\(.name)"] \| join(","))"'` | 3 bindings: `system:masters` (expected), **`claude-platform-owner` SA**, `longhorn-support-bundle` SA |
| A.8.2 | Binding not in git | `grep -rln claude-platform-owner kubernetes/` | **No output** — the cluster-admin binding exists nowhere in the GitOps source |
| A.8.2 | **Static tokens (F-05, F-06)** | `kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,CREATED:.metadata.creationTimestamp` | **2 non-expiring tokens**: `infraweaver-console/infraweaver-console-sa-token` (git-declared, scoped reader) and `infraweaver-system/claude-platform-owner-token` (**not in git, cluster-admin**) |

---

## 5. Change management and SDLC (A.8.4, A.8.25, A.8.29, A.8.32)

| Control | Artifact | Command | Expected / actual |
|---|---|---|---|
| **A.8.32** | **Branch protection unavailable (RISK-02)** | `gh api repos/example-owner/InfraWeaver-infra/branches/main/protection` | **HTTP 403** `"Upgrade to GitHub Pro or make this repository public…"`. The single most important negative evidence in this pack |
| A.8.32 | **Push-triggered apply (RISK-02/04)** | `grep -nE 'on:\|branches:\|make apply' <infrastructure>/.github/workflows/tofu.yml` | `push: branches: [main, ontwikkel]` … `run: ENV=… make apply` at line 151 |
| A.8.29 | CI gate definitions | `ls -1 .github/workflows/ && grep -n 'name:' .github/workflows/validate-iac.yml \| head` | `validate-iac.yml`, `validate-code.yml`, `build-cmp-tools.yml`, `sync-to-public.yml` |
| A.8.29 | 5-stage IaC gate | `grep -nE '── [0-9]/5' scripts/validate-iac.sh` | kustomize build · kubeconform · secret-leak gate · cron-secret seed gate · alert-rule (promtool) |
| A.8.29 | Secret-leak baseline | `grep -A6 'Known pre-existing raw Secrets' scripts/validate-iac.sh` | Baseline list is **empty** — every previously committed raw Secret has been migrated to ExternalSecret/OpenBao |
| A.8.29 | Incident-derived netpol gate | `head -30 scripts/validate-netpol-ports.sh` | Documents the `allow-traefik-ingress` SSO outage it exists to prevent |
| A.8.29 | Infra security gates | `grep -nE 'checkov\|tfsec\|soft_fail\|sops' <infrastructure>/.github/workflows/security-scan.yml \| head` | Checkov `soft_fail: false` + fail-on-HIGH; tfsec fail on CRITICAL/HIGH; SOPS encryption validation; aggregate policy gate |
| A.8.4 | Public-mirror guard | `head -25 scripts/git-hooks/pre-push` | Blocks direct pushes to the public template mirror; bypass requires `ALLOW_PUBLIC_PUSH=1` |
| A.8.9 | GitOps reconciliation | `kubectl get applications.argoproj.io -A -o json \| jq -r '[.items[].spec.project] \| group_by(.) \| map({(.[0]): length}) \| add'` | `{"default":6,"infraweaver-prod":9,"platform":46}` — **6 apps in the unrestricted `default` project (F-07)** |
| A.8.9 | Unrestricted apps named | `kubectl get applications.argoproj.io -A -o json \| jq -r '.items[] \| select(.spec.project=="default") \| .metadata.name'` | `catalog-game-hub-networks`, `core-metallb-manifests`, `core-network-policies`, `external-routes`, `private-test`, `tradesphere` |
| A.8.9 | Drift / health | `kubectl get applications.argoproj.io -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers \| grep -v 'Synced *Healthy'` | 4 not-Healthy at 10:46 on 2026-08-07: `bootstrap`, `catalog-game-hub-servers`, `catalog-infraweaver-console-manifests` (Degraded) and `tradesphere` (OutOfSync + Degraded). `catalog-game-hub-namespace` was `Progressing` 20 minutes earlier — this set fluctuates |
| A.8.32 | Change history | `git log --oneline -20` | Reviewable commit history; conventional-commit format |

---

## 6. Policy enforcement and workload security (A.5.36, A.8.3, A.8.9, A.8.19)

| Control | Artifact | Command | Expected / actual |
|---|---|---|---|
| **A.5.36** | **Audit-only enforcement (RISK-10)** | `kubectl get cpol -o custom-columns=NAME:.metadata.name,ACTION:.spec.validationFailureAction` | 19 policies: **18 `Audit`, 1 `Enforce`** (`validate-externalsecret-storeref`) |
| A.5.36 | Live violations | `kubectl get polr -A -o json \| jq -r '[.items[].summary] \| {pass:(map(.pass)\|add), fail:(map(.fail)\|add), error:(map(.error)\|add)}'` | `{"pass":2024,"fail":39,"error":2}` — the 2 errors are the broken `require-pod-probes` policy |
| A.8.3, A.8.9 | PSA levels | `kubectl get ns -o json \| jq -r '.items[] \| "\(.metadata.name)\tenforce=\(.metadata.labels["pod-security.kubernetes.io/enforce"] // "-")"'` | 37 namespaces; **12 with no enforce label** (inherit cluster default `baseline`); `jellyfin` is `privileged` unnecessarily; only `private-test` and `tradesphere` are `restricted` |
| A.8.19 | Software provenance | `kubectl get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' \| sort -u \| grep -c .` `80` distinct container images (`83` including initContainers), across 9 registries: docker.io 36, quay.io 16, registry.k8s.io 13, ghcr.io 12, registry.int 3, plus oci.external-secrets.io / lscr.io / ecr-public.aws.com |
| A.8.19 | `:latest` offenders | `kubectl get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' \| sort -u \| grep -E ':latest$\|^[^:]*$'` | `bitnami/kubectl:latest`, `benjojo/alertmanager-discord:latest`, untagged `lscr.io/linuxserver/jellyfin`. RISK-15 |

---

## 7. Network security and segmentation (A.8.20, A.8.21, A.8.22)

| Control | Artifact | Command | Expected / actual |
|---|---|---|---|
| A.8.22 | NetworkPolicy coverage | `kubectl get netpol -A --no-headers -o custom-columns=NS:.metadata.namespace \| sort \| uniq -c` | 14 namespaces with NetworkPolicies (argocd 11, authentik 12, openbao 12 …) |
| A.8.22 | CiliumNetworkPolicy coverage | `kubectl get cnp -A --no-headers -o custom-columns=NS:.metadata.namespace \| sort \| uniq -c` | 25 namespaces with airgap-baseline CNPs (`infraweaver-console` 14, `wordpress` 10 …) |
| **A.8.20** | **Unpolicied namespaces (RISK-14)** | `comm -23 <(kubectl get ns -o name \| cut -d/ -f2 \| sort) <(kubectl get netpol,cnp -A -o json \| jq -r '.items[].metadata.namespace' \| sort -u)` | Returns 10: `bootstrap`, `cilium-secrets`, `crds`, `default`, `local-path-storage`, `metallb-system`, **`velero`** (which runs `minio-velero`) — plus `kube-system`, `kube-public`, `kube-node-lease`, which are accepted system namespaces. **7 actionable** |
| A.8.21 | Edge middleware | `kubectl get ingressroutes -A -o json \| jq -r '.items[] \| "\(.metadata.namespace)/\(.metadata.name): \([.spec.routes[].middlewares[]?.name] \| join(","))"'` | 26 IngressRoutes. **`bitwarden` = secure-headers only (RISK-06); `jellyfin` and `nextcloud` = no middleware at all.** forward-auth correctly on argocd/grafana/longhorn/n8n/openbao/truenas/console/gatus |
| A.8.24 | TLS issuance | `kubectl get clusterissuers -o custom-columns=NAME:.metadata.name,SERVER:.spec.acme.server --no-headers` | `letsencrypt-dns` / `letsencrypt-http` on `acme-v02.api.letsencrypt.org`, staging pair, plus `infraweaver-ca` self-signed |
| A.5.23 | DNS provider | `kubectl get deploy -n external-dns -o jsonpath='{.items[*].spec.template.spec.containers[*].args}' \| tr ',' '\n' \| grep -iE 'provider\|domain'` | `--provider=cloudflare`, `--domain-filter=example.com` |

---

## 8. Backup, continuity and storage (A.5.29, A.5.30, A.8.13, A.8.14)

**This section is where the platform fails hardest. The commands are listed so
the failure is verifiable, not so it is hidden.**

| Control | Artifact | Command | Expected / **actual on 2026-08-07** |
|---|---|---|---|
| **A.8.13** | **Backup target broken (RISK-03)** | `kubectl get backuptarget -n longhorn-system -o json \| jq -r '.items[] \| "url=[\(.spec.backupTargetURL)] available=\(.status.available)"'` | **`url=[] available=false`** — git declares `nfs://…:/mnt/pool/k8s-longhorn-backups`. **FAIL** |
| **A.8.13** | **No backups exist** | `kubectl get backups.longhorn.io -n longhorn-system` | **`No resources found`** — zero volume backups have ever been created. **FAIL** |
| **A.5.30** | **Verifier never succeeded** | `kubectl get cronjob -n longhorn-system -o custom-columns=NAME:.metadata.name,SCHEDULE:.spec.schedule,LASTSCHEDULE:.status.lastScheduleTime,LASTSUCCESS:.status.lastSuccessfulTime` | `longhorn-backup-verifier` schedule `30 3 * * *`, last scheduled 2026-08-07T03:30, **`lastSuccessfulTime` empty — never once succeeded.** `local-snapshot-daily`, `truenas-backup-daily/weekly` and `longhorn-replica-guardian` **do** show recent successes |
| A.8.13 | Velero absent | `kubectl get pods -n velero` | Only `minio-velero` + a completed bucket-create job. **Velero itself is not deployed** |
| A.5.9 | Data at risk | `kubectl get pvc -A --no-headers \| wc -l && kubectl get volumes.longhorn.io -n longhorn-system --no-headers \| wc -l` | **39 PVCs / 19 Longhorn volumes** — the scope of what is currently unprotected |
| A.8.14 | Declared backup target | `grep -n 'backupTarget' kubernetes/core/longhorn/values.yaml` | Line 98: `nfs://10.1.0.135:/mnt/pool/k8s-longhorn-backups`. **WP2 committed the git-side repair in `1b3e871` at 2026-08-07 10:39; the live BackupTarget above was still empty at 10:47 — git is fixed, the cluster has not converged. Re-run both and compare** |
| A.5.29 | DR procedure exists | `grep -nE '^#{1,2} ' docs/PRIVATE-PUBLIC-GITOPS-AND-DR.md` | Phase 1 (private-source cutover) and Phase 2 (DR rebuild, marked SUPERVISED) |

---

## 9. Logging, monitoring and detection (A.5.28, A.8.15, A.8.16)

| Control | Artifact | Command | Expected / actual |
|---|---|---|---|
| A.8.16 | Alert rule coverage | `kubectl get prometheusrules -A --no-headers \| wc -l` | `37` PrometheusRules |
| **A.8.16** | **Watchdog routed to null (RISK-12)** | `kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager -o jsonpath='{.data.alertmanager\.yaml}' \| base64 -d \| sed -n '/^route:/,$p'` | First route: `alertname = "Watchdog" → receiver: "null"`. **The dead-man's-switch is discarded.** `severity=critical → all`, `severity=warning → discord` — one vendor for everything |
| A.8.16 | Unrouted email fallback | same command, `grep -A4 'email-admin'` | Receiver `email-admin` exists with `to: admin@${BASE_DOMAIN}` — **unrouted, and the placeholder is unsubstituted**, so it would fail even if routed |
| A.8.15 | Metric retention | `grep -n 'retention' kubernetes/monitoring/kube-prometheus-stack/values.yaml` | `retention: 3d`, `retentionSize: 8GB` — **too short for a Type II window (RISK-12)** |
| A.8.15 | Log retention | `grep -n 'retention' kubernetes/monitoring/loki/values.yaml` | `retention_period: 168h` with deletes disabled — **undefined in practice** |
| **A.8.7** | **No runtime detection (RISK-11)** | `kubectl get pods -n falco` | **`No resources found`** — Falco disabled |
| A.8.15 | **No OpenBao audit (F-08)** | `ls kubernetes/core/openbao/manifests/` | Only `networkpolicy.yaml` and `rbac.yaml` — **no audit device configuration; secret access is unevidenced** |

---

## 10. Secrets management (A.5.17, A.8.24)

| Control | Artifact | Command | Expected / actual |
|---|---|---|---|
| A.8.24 | ESO health | `kubectl get externalsecrets -A --no-headers \| wc -l` | `28` ExternalSecrets |
| **A.8.24** | **Failing syncs (RISK-13)** | `kubectl get externalsecrets -A -o json \| jq -r '.items[] \| select([.status.conditions[]?\|select(.type=="Ready")\|.status]\|index("True")\|not) \| "\(.metadata.namespace)/\(.metadata.name)"'` | **5 failing**: `game-hub/game-hub-server-credentials`, `infraweaver-console/infraweaver-iwsl-iw-keys`, `tradesphere/{ai,binance,inspect}` |
| A.8.24 | Plaintext credential in pod spec | `kubectl get pods -n game-hub -o json \| jq -r '.items[].spec.containers[].env[]? \| select(.name\|test("RCON")) \| "\(.name) valueFrom=\(.valueFrom != null)"'` | `RCON_PASSWORD valueFrom=false` and `_IW_RCON_PASSWORD valueFrom=false` → **literal passwords in the pod spec**, readable by anyone with pod-read in that namespace. RISK-13 |
| A.8.24 | Storage classes | `kubectl get sc --no-headers -o custom-columns=NAME:.metadata.name,PROV:.provisioner` | `longhorn`(+ retain/static/game), `local-path`(+ retain) |

---

## 11. Access review and vendor evidence

| Control | Artifact | Command | Expected |
|---|---|---|---|
| A.5.18 | Executed review | `docs/compliance/access-review-2026-Q3.md` | First review, 2026-08-07, 10 findings across 5 surfaces |
| A.5.18 | Review procedure | `docs/compliance/access-review-procedure.md` | Quarterly, 5 mandatory surfaces, all commands read-only |
| A.5.19 | Vendor register | `docs/compliance/vendor-register.md` | Every supplier with data-touched, criticality and **exit path** |
| A.5.23 | Data egress inventory | `vendor-register.md` §3 | Confirms **no user content leaves the platform** |

---

## 12. Known evidence gaps

Stated so an auditor does not have to find them:

| Gap | Why | Owner |
|---|---|---|
| **No evidence over time.** Every command shows *current* state. With 3-day metric retention and undefined log retention, there is no historical series proving continuous control operation | RISK-12 | WP8 |
| **No OpenBao access evidence.** No audit device, so secret reads are unrecorded and unreviewable | F-08 / GAP-M6 | WP10 |
| **No restore evidence.** No backup has ever completed, therefore no restore has ever been tested | RISK-03 | WP2 |
| **No independent verification.** Every command here was run by the party being audited | A.5.35, RISK-08 | Unowned — structural |
| **Proxmox, TrueNAS, Synology, GitHub and OpenBao access** are evidenced by inspection, not by API-derived output | Surface 5 of the Q3 review | Next review |

---

## 13. Quick verification run

To re-establish the top-line control picture in one pass:

```bash
export KUBECONFIG=/home/runner/.kube/config-platform-productie
export TALOSCONFIG=/home/runner/.talos/config
kubectl get nodes -o wide
kubectl get applications.argoproj.io -A -o json | jq -r '[.items[].spec.project] | group_by(.) | map({(.[0]): length}) | add'
kubectl get cpol -o custom-columns=NAME:.metadata.name,ACTION:.spec.validationFailureAction
kubectl get polr -A -o json | jq -r '[.items[].summary] | {pass:(map(.pass)|add), fail:(map(.fail)|add), error:(map(.error)|add)}'
kubectl get backuptarget -n longhorn-system -o json | jq -r '.items[] | "url=[\(.spec.backupTargetURL)] available=\(.status.available)"'
kubectl get backups.longhorn.io -n longhorn-system
kubectl get externalsecrets -A -o json | jq -r '.items[] | select([.status.conditions[]?|select(.type=="Ready")|.status]|index("True")|not) | "\(.metadata.namespace)/\(.metadata.name)"'
kubectl get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'
kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name
gh api repos/example-owner/InfraWeaver-infra/branches/main/protection   # expect 403 until WP1
talosctl -n 10.0.0.90 time
python3 docs/compliance/scripts/generate-asset-inventory.py --stdout | head -40
```

Every line is read-only. Nothing above will change the state of a production
system (A.8.34).
