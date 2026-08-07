# Access Review Procedure

| | |
|---|---|
| **Document ID** | ISMS-PRO-001 |
| **Version** | 1.0 |
| **Status** | Active |
| **Effective** | 2026-08-07 |
| **Owner** | Platform Owner |
| **Cadence** | Quarterly (Q1 Feb, Q2 May, Q3 Aug, Q4 Nov), first working day of the month |
| **Controls** | ISO/IEC 27001:2022 A.5.15, A.5.18, A.8.2, A.8.3 · SOC 2 CC6.1, CC6.2, CC6.3 |

---

## 1. Purpose

Prove, on a schedule, that every principal that can reach this platform still
needs the access it holds. Closes GAP-M8.

## 2. Reviewer

The Platform Owner reviews their own access. There is no second reviewer; see
`information-security-policy.md` §3. The mitigation for self-review is that the
procedure is **mechanical** — the reviewer runs fixed commands and records what
they return, rather than recalling from memory who should have what. A finding
that appears in the command output must be recorded even when the reviewer
believes it is fine; the belief goes in the disposition column, not in whether
the row exists.

## 3. Scope — the five authorisation surfaces

A review is complete only when all five are covered. Checking `users.yaml` alone
is not a review: a user removed from `users.yaml` can still authenticate.

| # | Surface | Why it is separate |
|---|---|---|
| 1 | `users.yaml` role assignments | The register of intent |
| 2 | Authentik users, groups, memberships, and MFA enrolment | The actual authentication authority |
| 3 | Authentik application access policy bindings | Which apps an authenticated user can reach |
| 4 | ArgoCD RBAC (`policy.csv`) and Kubernetes RBAC (cluster-admin bindings, ServiceAccount tokens) | Machine and deployment authority |
| 5 | Non-Kubernetes access: Proxmox, TrueNAS/Synology, GitHub, OpenBao | Outside the cluster, easy to forget |

## 4. Method

All commands are **read-only**. Run from a machine with `kubectl` and `gh`
access. Record raw output in the review record; do not paraphrase it.

### Step 1 — `users.yaml` register

```bash
cd <InfraWeaver-infra>
python3 - <<'PY'
import yaml
d = yaml.safe_load(open("users.yaml"))
for uid, u in (d.get("users") or {}).items():
    ras = u.get("role_assignments") or []
    print(f"{uid} <{u.get('email','-')}> level={u.get('access_level','-')} grants={len(ras)}")
    for ra in ras:
        print(f"    {ra.get('roleId')} @ {ra.get('scope')} effect={ra.get('effect','Allow')} by={ra.get('grantedBy')} on={ra.get('grantedAt')}")
PY
```

For each grant ask: is the person still active, is the scope still the narrowest
that works, and is the `grantedAt` older than the reason for the grant?

### Step 2 — Authentik users, groups, MFA

```bash
# Users
kubectl exec -n authentik authentik-postgresql-0 -- bash -c \
 'PGPASSWORD="$(cat $POSTGRES_PASSWORD_FILE)" psql -U authentik -d authentik -tAF"|" -c
  "SELECT username, is_active, type, coalesce(to_char(last_login,'"'"'YYYY-MM-DD'"'"'),'"'"'never'"'"'),
          to_char(date_joined,'"'"'YYYY-MM-DD'"'"') FROM authentik_core_user ORDER BY username;"'

# Group membership
kubectl exec -n authentik authentik-postgresql-0 -- bash -c \
 'PGPASSWORD="$(cat $POSTGRES_PASSWORD_FILE)" psql -U authentik -d authentik -tAF"|" -c
  "SELECT u.username, g.name FROM authentik_core_user u
     JOIN authentik_core_user_groups ug ON ug.user_id=u.id
     JOIN authentik_core_group g ON g.group_uuid=ug.group_id ORDER BY 1,2;"'

# Second-factor enrolment (must not be all zero once WP11 lands)
kubectl exec -n authentik authentik-postgresql-0 -- bash -c \
 'PGPASSWORD="$(cat $POSTGRES_PASSWORD_FILE)" psql -U authentik -d authentik -tAF"|" -c
  "SELECT '"'"'totp'"'"', count(*) FROM authentik_stages_authenticator_totp_totpdevice
   UNION ALL SELECT '"'"'webauthn'"'"', count(*) FROM authentik_stages_authenticator_webauthn_webauthndevice
   UNION ALL SELECT '"'"'static'"'"', count(*) FROM authentik_stages_authenticator_static_staticdevice;"'
```

The password is read inside the pod and never printed. Do not copy it out.

Cross-check: every active Authentik user must appear in `users.yaml`, and every
`users.yaml` user must exist in Authentik. Both directions — an orphan in either
is a finding.

### Step 3 — Authentik application bindings

```bash
kubectl exec -n authentik authentik-postgresql-0 -- bash -c \
 'PGPASSWORD="$(cat $POSTGRES_PASSWORD_FILE)" psql -U authentik -d authentik -tAF"|" -c
  "SELECT a.slug FROM authentik_core_application a
    WHERE NOT EXISTS (SELECT 1 FROM authentik_policies_policybinding b
                      WHERE b.target_id = a.policybindingmodel_ptr_id) ORDER BY 1;"'
```

An application with no binding is reachable by **any** authenticated user. For
each result decide: intended (a service everyone should reach), stale (the
service no longer exists — deregister it), or a finding.

### Step 4 — ArgoCD and Kubernetes

```bash
kubectl get cm argocd-rbac-cm -n argocd -o jsonpath='{.data.policy\.csv}'; echo
kubectl get cm argocd-cm -n argocd -o jsonpath='{.data.admin\.enabled}'; echo
kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin")
           | "\(.metadata.name): \([.subjects[]? | "\(.kind)/\(.namespace // "-")/\(.name)"] | join(","))"'
kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,AGE:.metadata.creationTimestamp
kubectl get applications.argoproj.io -A -o json \
  | jq -r '[.items[].spec.project] | group_by(.) | map({(.[0]): length}) | add'
```

Any static ServiceAccount token Secret is a finding by policy
(`access-control-policy.md` §6). Any cluster-admin subject that is not
`system:masters` or a documented operator-managed binding is a finding.

### Step 5 — Outside the cluster

Checked by inspection, recorded as an assertion with a date because there is no
API-derived evidence for all of them:

- Proxmox users/API tokens on `10.1.0.3` and `10.1.0.4`.
- TrueNAS and Synology service accounts (`infraweaver-svc`) and their share
  permissions; credentials live at `secret/platform/nas/providers` in OpenBao.
- GitHub: collaborators on the three repositories, plus Actions secrets.
- OpenBao: policies and any long-lived tokens.

## 5. Recording

Each review produces `access-review-<YYYY>-Q<n>.md` in this directory,
containing: date, reviewer, the five surfaces with their raw findings, a
disposition per principal (**Retain / Reduce / Revoke / Investigate**), and an
action list with owners. Findings that cannot be closed during the review become
risk-register entries or work-package items — never a note that evaporates.

## 6. Timeliness

A review not completed within 14 days of its due date is itself a control
failure and is recorded in the risk register. The first review was executed on
2026-08-07; the next is due **2026-11-02**.
