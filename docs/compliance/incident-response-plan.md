# Incident Response Plan

| | |
|---|---|
| **Document ID** | ISMS-PLA-001 |
| **Version** | 1.0 |
| **Status** | Active |
| **Effective** | 2026-08-07 |
| **Owner** | Platform Owner (sole responder) |
| **Next review** | 2027-02-07, and after every SEV-2 or higher incident |
| **Controls** | ISO/IEC 27001:2022 A.5.24, A.5.25, A.5.26, A.5.27, A.5.28, A.6.8, A.8.16 · SOC 2 CC7.3, CC7.4, CC7.5 |

---

## 1. Scope and the honest staffing statement

This plan covers security incidents affecting the InfraWeaver platform: the
Kubernetes cluster, the Proxmox hosts, the GitOps repositories, Authentik,
OpenBao, and the data of users hosted on the platform.

**There is one responder.** Every role that a normal incident plan distributes —
commander, investigator, communicator, scribe — is the same person. This plan
therefore does not assign roles; it assigns an **order of operations**, because
the failure mode for a single responder is not confusion about who acts, it is
doing things in the wrong order under stress and destroying evidence or
availability in the process.

Two consequences are stated up front rather than discovered during an incident:

- **There is no 24/7 coverage and no escalation path.** If the responder is
  asleep, unwell, or away, response begins when they return. Detection may be
  automated; response is not.
- **There is no second pair of eyes** on containment decisions. The mitigation
  is §4's rule: prefer reversible actions, and write down what you did *as you
  do it*, because there is nobody else who knows.

## 2. Existing material this plan builds on

This plan does **not** restate procedures that already exist. Use them directly:

| Situation | Use |
|---|---|
| Credential rotation (Cloudflare, Proxmox, SMTP, deployer SSH key, git history scrub) | `docs/SECURITY-REMEDIATION-RUNBOOK.md` §C-1 — five numbered, tested rotation procedures |
| Cluster CA / kubeconfig compromise | `docs/SECURITY-REMEDIATION-RUNBOOK.md` §C-4 — `talosctl rotate-ca` and the caveat that it is disruptive |
| Full DR rebuild with all-new secrets | `docs/PRIVATE-PUBLIC-GITOPS-AND-DR.md` §Phase 2 (marked SUPERVISED; catastrophic if unattended) |
| Data loss / restore | `business-continuity-plan.md` (and, once WP2 lands, `docs/BACKUP-AND-RESTORE-RUNBOOK.md`) |
| What is deliberately accepted and therefore is *not* an incident | `risk-register.md` |

**Known pre-existing exposures that the runbook lists as still-open operator
actions**, and which shape any incident involving the runner VM (`github-runner`,
VM 107 on `10.1.0.3`): real secrets exist in plaintext `.env` files on that
host, and `envs/productie/generated/` holds the Talos CA private key and admin
kubeconfig/talosconfig unencrypted. **Compromise of the runner VM is therefore a
SEV-1 by definition** — it is equivalent to compromise of the cluster CA.

## 3. Severity classification

| Level | Definition | Examples on this platform | Target response start |
|---|---|---|---|
| **SEV-1** | Confirmed compromise of a credential or system that grants control of the platform, or confirmed loss/exfiltration of user data | Runner VM compromise (plaintext `.env` + Talos CA); `claude-platform-owner` token disclosed; Authentik admin account compromised; OpenBao unsealed by an unauthorised party; Proxmox root access | Immediate, drop everything |
| **SEV-2** | Compromise of a scoped credential or single service, or a control failure with active exposure | A single application credential leaked; a public endpoint found unauthenticated; a WordPress site defaced; an ExternalSecret exposing a value | Same day |
| **SEV-3** | Control failure with no evidence of exploitation | A secret committed to git and caught by the CI gate; a NetworkPolicy accidentally removed; a Kyverno enforce policy bypassed | Within 72 hours |
| **SEV-4** | Security-relevant event needing a record but no urgent action | Repeated failed logins; an unexpected image pull; a policy violation appearing in a PolicyReport | Next working session |

**Escalation rule for a single responder:** when the severity is genuinely
unclear, treat it as one level *higher* for the first 30 minutes. Downgrading
after triage is cheap; discovering at hour six that a SEV-2 was a SEV-1 is not.

## 4. Response sequence

### Phase 0 — Record before you act (2 minutes, non-negotiable)

Open a file `docs/compliance/incidents/INC-<YYYYMMDD>-<n>.md` and write: the
timestamp, what you observed, and where you observed it. Then keep appending as
you go. With one responder there is no scribe; if it is not written while it
happens it does not exist afterwards.

### Phase 1 — Triage

Answer three questions, in this order:

1. **Is it real?** Distinguish an alert from an incident. Note that this
   platform's most common failure shape is a **200 response with an empty body
   plus a marker** (`X-Data-Source: unavailable`, `live: false`,
   `available: false`) — an error condition that does not look like an error.
   `live` is not the same as `available`.
2. **What identity or system is implicated?** Map it to the asset inventory.
3. **What severity?** Per §3.

### Phase 2 — Contain

Preference order, because a single responder cannot easily undo a destructive
containment step:

1. **Revoke access** — deactivate the Authentik account, delete the token
   Secret, remove the role assignment. Reversible.
2. **Cut the path** — remove the IngressRoute or apply a deny NetworkPolicy.
   Reversible and does not destroy state.
3. **Isolate the workload** — scale to zero rather than delete. Preserves the
   PVC and the pod spec for investigation.
4. **Only then** stop a node or a VM. This costs availability on a three-node
   converged cluster where losing one node removes etcd fault tolerance
   (RISK-01).

**Never** delete a compromised pod before capturing its logs and spec —
`kubectl logs` and `kubectl get pod -o yaml` first, always. Loki holds only what
its retention allows (currently undefined in practice, RISK-12), so pod logs may
be the *only* copy.

### Phase 3 — Eradicate

- Rotate every credential the incident could plausibly have touched, not only
  the one proven exposed. Use `SECURITY-REMEDIATION-RUNBOOK.md` §C-1.
- **Rotate, do not rewrite.** If a secret reached git, treat it as disclosed
  from the moment of the commit. Force-pushing history does not un-disclose it
  and this platform pushes to a public template mirror.
- Fix the defect in **git**, not in the cluster. A `kubectl patch` fix is undone
  by the next ArgoCD sync — 60 of 61 Applications auto-sync.

### Phase 4 — Recover

- Restore from backup per `business-continuity-plan.md`. **Read that document's
  status section first** — volume backups have never successfully run
  (RISK-03), so "restore from backup" is not currently a real option for most
  PVCs.
- Verify recovery with the evidence commands in `evidence-index.md`, not by
  looking at a green dashboard.

### Phase 5 — Learn (A.5.27)

Within 7 days of a SEV-1 or SEV-2, complete the post-mortem in §8 and:

- Add or update an entry in `risk-register.md`.
- Add a detection for the thing that was missed — an alert rule, a CI gate, a
  Kyverno policy. **An incident that produces no new detection will recur.**
- If the incident revealed an access problem, run an off-cycle access review.

## 5. Detection sources

| Source | Covers | Known limitation |
|---|---|---|
| Prometheus + Alertmanager (37 PrometheusRules) | Resource, availability, CronJob-miss alerting | **3-day metric retention**; single Discord webhook receiver; several routes go to `null`; no dead-man's-switch (RISK-12, GAP-M4) |
| Loki | Application and platform logs | Retention undefined in practice; API server audit logs are **not** shipped to it |
| Kubernetes API audit log | API-level actions, Metadata level | **Stays on-node** at `/var/log/audit/kube/`, 30-day file rotation. Lose the node, lose the trail |
| Kyverno PolicyReports | Admission-time policy violations | 18 of 19 policies are Audit-only — they record, they do not prevent |
| Cilium Hubble | Network flows | Observability only; no alerting wired |
| Gatus | External synthetic checks | Availability only |
| **Runtime threat detection** | — | **None. Falco is disabled** (RISK-11) |
| **OpenBao secret access** | — | **None. No audit device configured** (F-08 / GAP-M6) |

Reporting a suspected incident (A.6.8): platform users have no formal channel.
For five users this is handled by direct contact with the operator. Stated as a
limitation, not claimed as a control.

## 6. Communication

| Audience | When | How |
|---|---|---|
| Affected platform users | SEV-1/SEV-2 touching their data, within 72 hours of confirmation | Direct email to the address in `users.yaml` |
| Supervisory authority (GDPR Art. 33) | Personal-data breach likely to result in risk to individuals, within 72 hours of becoming aware | Dutch DPA (Autoriteit Persoonsgegevens). **This obligation has never been exercised or rehearsed** |
| Third parties | Where their service is implicated (see `vendor-register.md`) | Vendor's own security contact |

There is no PR function, no legal counsel, and no customer-success path. For a
platform hosting a handful of personal WordPress sites and media libraries, the
communication plan is "tell the affected people directly and quickly".

## 7. Playbook: credential compromise (the most likely incident)

1. **Record** (Phase 0).
2. **Scope it.** Which credential, what does it reach, since when? For a
   Kubernetes token: `kubectl get clusterrolebindings -o json | jq …` to
   establish reach.
3. **Revoke first, investigate second.** Delete the token Secret / deactivate
   the account / roll the API token. Availability loss is recoverable;
   continued attacker access is not.
4. **Rotate the blast radius**, per `SECURITY-REMEDIATION-RUNBOOK.md` §C-1 —
   Cloudflare, Proxmox, SMTP, deployer SSH key, and OpenBao paths that share it.
5. **Hunt** in the API audit log on-node
   (`talosctl -n 10.0.0.90 read /var/log/audit/kube/kube-apiserver.log` — note
   the 30-day horizon) and in Loki.
6. **If the runner VM is implicated**, treat the Talos CA as compromised and go
   to `SECURITY-REMEDIATION-RUNBOOK.md` §C-4 (`talosctl rotate-ca`). This is
   disruptive and needs a window; do not start it at 02:00 without one.
7. **Post-mortem** (§8).

## 8. Post-mortem template

```markdown
# INC-<YYYYMMDD>-<n>: <one-line title>

- Severity:            SEV-<n>
- Detected:            <timestamp> by <source>
- Contained:           <timestamp>
- Resolved:            <timestamp>
- Data affected:       <none | which users, what data>
- Notification needed: <no | who, when, done?>

## Timeline
<timestamp> — <what happened / what I did>

## Root cause
<the defect, not the symptom>

## Why detection was late (or absent)
<the honest answer; if it was luck, say so>

## What was rotated / changed
<list, with the git commit or command>

## Actions
| # | Action | Type (detection / prevention / process) | Where it lands |
|---|---|---|---|
| 1 | | | risk-register.md / WP-<n> / alert rule |

## Evidence retained
<paths, queries, and their retention horizon — note if anything will age out>
```

## 9. Testing this plan

Never tested. This plan was written on 2026-08-07 and has not been exercised
against a real or simulated incident.

**First exercise due 2026-11-07**: a tabletop of §7 (credential compromise) using
the `claude-platform-owner` token as the scenario, run alongside the WP3 work
that removes it. A DR game-day capability exists in the console
(`api/dr/game-days`) and should be used for the recovery half.

Recording the absence of testing is deliberate. An untested incident plan is a
document; the gap between the two should be visible to whoever reads this.
