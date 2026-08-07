# Break-glass — regaining administrative access

**Scope:** how to get back into this platform when the normal way in does not
work. Written for one person, under pressure, possibly at 03:00, possibly from
a phone.

**Why it exists:** Authentik is the single lock on every administrative surface
here — ArgoCD, the InfraWeaver console, Grafana, Longhorn, OpenBao, TrueNAS,
the Traefik dashboard, Portainer, Proxmox. Most of those have no login page of
their own; forward-auth *is* their authentication. And this platform has
essentially one administrator. Adding a second factor to that lock without a
tested way past it converts a lost phone into a total loss of administrative
access.

> **Status as of 2026-08-07:** the break-glass account below is created by
> GitOps but ships **dormant** — inactive, no password. It has never been
> armed and never been exercised. Until §3 and §7 have both been completed and
> logged, this document describes an intention, not a control. **MFA
> enforcement (WP11 stage 4) must not be attempted before then.**

---

## 1. Which situation are you in?

Work down. Stop at the first row that matches.

| # | Symptom | Go to |
| --- | --- | --- |
| T0 | `auth.example.com` loads, but you cannot complete login — lost/broken second factor, or an MFA change locked you out | §3 then §4 |
| T1 | `auth.example.com` is down, erroring, or every app returns a forward-auth failure | §5 |
| T2 | The Kubernetes API itself is unreachable | §6 |

A useful early discriminator, since it needs no credentials at all:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://auth.example.com/-/health/live/
kubectl get pods -n authentik
```

---

## 2. The dependency map — read this once, now, not during an incident

```
                      ┌──────────────────────┐
  browser ──────────► │  Authentik           │
                      │  auth.example.com  │
                      └──────────┬───────────┘
                                 │ forward-auth / OIDC
   ┌────────────┬────────────┬───┴────┬────────────┬────────────┐
 ArgoCD      Console      Grafana  Longhorn     OpenBao      TrueNAS
 (no local   (no local    (fwd)    (no auth     (fwd on UI)  (local root
  login)      login)                of its own)               exists)

                      ┌──────────────────────┐
  kubeconfig ───────► │  Kubernetes API      │  ← bypasses ALL of the above
                      └──────────────────────┘
```

Three facts that decide everything below:

- **ArgoCD has no local login.** `argocd-cm` carries `admin.enabled: false`, and
  `argocd-secret` holds only `server.secretkey` — there is no `admin.password`.
  If Authentik cannot authenticate you, the ArgoCD UI and `argocd login` are
  both closed. Managing Applications as Kubernetes CRs is the fallback.
- **`kubectl` is the universal fallback and the real ceiling.** Anyone who can
  `kubectl exec` into the Authentik pod is unconditionally an Authentik
  administrator. MFA raises the floor for browser access; it does not change
  this. Treat the kubeconfig with the same seriousness as the break-glass
  password.
- **OpenBao is not a safe home for break-glass credentials.** Its UI sits
  behind forward-auth (`openbao-fwd` → `policy-infra-vault`), so an Authentik
  outage takes it with you. Its API is still reachable via port-forward with a
  root token — which is itself a credential you must have stored somewhere
  outside the platform.

---

## 3. Arming the break-glass account (do this **before** you need it)

The account is declared in
`kubernetes/platform/authentik/manifests/blueprints/00-break-glass-account.yaml`
with `state: created`, so arming it is permanent — no later blueprint run
disarms it. It is a member of `authentik Admins` (superuser) and deliberately
**not** a member of `platform-admins`, which is the group MFA enforcement is
scoped to. That membership choice is the whole reason the escape hatch stays
open.

1. Confirm the account exists and is currently dormant:

   ```bash
   kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
   from authentik.core.models import User
   u = User.objects.filter(username="break-glass").first()
   print(u, u and u.is_active, u and [g.name for g in u.ak_groups.all()], u and u.is_superuser)
   PY
   ```

2. Generate a password of at least 32 random characters. Do not compose one.

3. Set it, and activate the account:

   ```bash
   kubectl exec -it -n authentik deploy/authentik-server -c server -- ak changepassword break-glass
   kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
   from authentik.core.models import User
   u = User.objects.get(username="break-glass"); u.is_active = True; u.save()
   print("active:", u.is_active, "superuser:", u.is_superuser)
   PY
   ```

   `ak changepassword` prompts interactively and does not echo. Do not pass the
   password on a command line — it lands in shell history and in the audit log.

4. **Verify it, in a private window** (§7). An unexercised procedure is a hope.

5. Store it (§8) and record the drill (§9).

---

## 4. T0 — you are locked out of login, Authentik is healthy

### Path A — the break-glass account (no cluster access needed)

1. Private/incognito window → `https://auth.example.com/if/flow/default-authentication-flow/`
2. Sign in as `break-glass` with the offline password.
3. You should land on the user interface; `https://auth.example.com/if/admin/`
   gives you the admin interface.
4. Fix the cause — most often: Flows → `default-authentication-flow` → Stage
   Bindings → disable or delete the order-25 binding added by WP11 stage 4.
5. Re-enrol your own factor, verify a normal login works, then **rotate the
   break-glass password** (§8) because it has now been used.

If sign-in as `break-glass` fails with "Request has been denied", the account
is inactive or was never armed — go to Path B, then §3.

### Path B — a recovery key minted from the cluster

This needs `kubectl`. It is the strongest path available, because
`UseTokenView` calls Django's `login()` directly and never enters the flow
engine — it therefore bypasses every authenticator-validation stage. The token
is single-use and deleted on use.

```bash
kubectl exec -n authentik deploy/authentik-server -c server -- \
  ak create_recovery_key 30 admin 2>/dev/null | grep -v '^{'
```

The command prints a URL of the form
`https://auth.example.com/recovery/use-token/<key>/`. Open it within the 30
minutes. Treat that URL as a live password-equivalent for a superuser: do not
paste it into chat, a ticket, or anything that keeps history.

Prefer minting for `break-glass` over `admin` when the goal is only to repair
the account — it keeps your own identity out of the emergency path and keeps
the audit trail honest.

### Path C — direct database or shell

`ak shell` on the server pod is already unrestricted Django ORM access. There
is no scenario where you need `dbshell` and cannot use `ak shell`. If both are
unavailable, you are in T1.

---

## 5. T1 — Authentik is down or broken

Everything behind forward-auth fails **closed**. That is correct behaviour, and
it means you cannot fix Authentik through anything that depends on Authentik.

| Target | How to reach it without Authentik |
| --- | --- |
| Authentik itself | `kubectl -n authentik logs/exec/rollout`; check `authentik-postgresql-0` and `authentik-redis-master-0` first — the server is healthy far more often than its dependencies |
| ArgoCD | No UI login exists. Operate on CRs: `kubectl -n argocd get applications`, `kubectl -n argocd patch application <name> --type merge -p '{"spec":{"syncPolicy":null}}'` to stop auto-sync fighting a manual fix |
| Longhorn, Traefik dashboard, Homepage, console | `kubectl port-forward` to the service; forward-auth only guards the ingress path |
| OpenBao | `kubectl -n openbao port-forward svc/openbao 8200:8200`, then `BAO_ADDR=http://127.0.0.1:8200 bao login` with the offline root token. Seal is Shamir, 1 share, threshold 1, with an autounseal sidecar backed by the `openbao-unseal` Secret in the `openbao` namespace — if that Secret is lost, the offline unseal key is the only way back |
| Grafana | `kubectl -n apps-grafana port-forward` and use the local admin if one is configured — **verify this during the next drill rather than assuming it** |
| TrueNAS | Local `root` on the appliance, independent of this cluster |
| Proxmox | `root@pam` on each hypervisor, independent of this cluster |

To restore ArgoCD UI login temporarily you must set `admin.enabled: "true"` in
`argocd-cm` **and** add a bcrypt `admin.password` to `argocd-secret`. Both are
GitOps-managed, so self-heal will revert them — disable auto-sync on the argocd
Application first, or make the change in git. Prefer operating on CRs.

---

## 6. T2 — the cluster is unreachable

1. Talos: `talosctl -n <node-ip> ...` with the offline `talosconfig`.
2. Proxmox web UI or SSH on the hypervisors (`root@pam`) — VM console access to
   the Talos nodes.
3. Physical/IPMI access to the hypervisors.
4. Restore path: `docs/BACKUP-AND-RESTORE-RUNBOOK.md`.

Each of those credentials must be in the offline store (§8). If the only copy
of `talosconfig` lives on a machine that authenticates against this platform,
it is not a break-glass credential.

---

## 7. Testing — without weakening normal authentication

Neither test changes any configuration, so neither one weakens anything. That
is the point: a break-glass test you are reluctant to run is a break-glass test
that never runs.

**Test 1 — the account (quarterly, ~3 minutes).**
Private window → sign in as `break-glass` → confirm `/if/admin/` renders →
sign out → close the window. Confirm afterwards that Authentik recorded the
login:

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.events.models import Event
for e in Event.objects.filter(action="login").order_by("-created")[:5]:
    print(e.created, e.user.get("username"), e.client_ip)
PY
```

After WP11 stage 4 is live, this test also proves the exemption still holds:
`break-glass` must **not** be challenged for a second factor. If it is, the
group scoping has drifted and the escape hatch is closed — fix that before
anything else.

**Test 2 — the recovery-key path (semi-annually, ~2 minutes).**
Mint a 5-minute key for `break-glass` (never for `admin`), use it, confirm you
land authenticated, then confirm the token was consumed:

```bash
kubectl exec -n authentik deploy/authentik-server -c server -- \
  ak create_recovery_key 5 break-glass 2>/dev/null | grep -v '^{'
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.core.models import Token
print([(t.identifier, str(t.intent)) for t in Token.objects.all()])
PY
```

No `recovery`-intent token should remain. If one does, the URL is still live —
delete it.

**Test 3 — the offline store (annually).** Open the sealed envelope, read the
credentials, confirm they are current, reseal with a new date. A credential
that has silently rotated out from under the envelope is worse than none,
because you will trust it.

---

## 8. Credential handling

**What is stored:** the `break-glass` password; the OpenBao root token and
unseal key; `kubeconfig`; `talosconfig`; Proxmox `root@pam`; TrueNAS `root`.

**Where it is stored — two copies, both outside the platform:**

1. A sealed, dated paper envelope in a physical location whose access does not
   depend on this platform.
2. An offline password-manager vault (or an OS keychain) on a device that can
   authenticate without Authentik.

**Where it is emphatically not stored:**

- Not in OpenBao — its UI is gated by the very system you are recovering from.
- Not in `bitwarden.example.com`. That Vaultwarden is publicly routed with
  `secure-headers` only and no forward-auth (GAP-H6); it is both a single point
  of failure and, today, the weakest edge on the platform.
- Not in this repository, any ConfigMap, or any Kubernetes Secret.
- Not in a chat message, a ticket, or a screenshot.

**Rotation triggers — any one of these:**

- On any use of the break-glass account, immediately, before the incident is
  closed.
- Every 12 months regardless of use.
- When any person with access to the envelope changes.
- On any suspicion of exposure.

Rotation is §3 steps 2–5 again, followed by re-sealing the envelope with a new
date and a new §9 row.

---

## 9. Drill log

Nothing in this document counts as a control until this table has rows. Add
one per drill or rotation, and keep it in git — it is the evidence an auditor
will ask for under ISO 27001 A.5.17 / A.8.5 and SOC 2 CC6.1.

| Date | Who | What was exercised | Result | Follow-up |
| --- | --- | --- | --- | --- |
| _(pending)_ | | Test 1 — break-glass account login | | account is dormant; arm per §3 first |
| _(pending)_ | | Test 2 — recovery key path | | |
| _(pending)_ | | Test 3 — offline store audit | | |

---

## 10. Standing bypasses that already exist

These predate this document and are not created by it. They are listed because
a break-glass procedure that ignores the unofficial back doors is describing a
different system than the one you run. Inventory them; decide on each.

Measured 2026-08-07:

| Token | Intent | Expires | What it grants |
| --- | --- | --- | --- |
| `iw-admin-token` | api | **never** | Full Authentik API as `admin`. Bypasses the login flow entirely, therefore bypasses **all** MFA. Can mint recovery keys and edit stages. |
| `recovery-admin` | verification | **never** | Drives the recovery flow without email: permanent password reset for the only superuser. Does not create a session, so it is not by itself an MFA bypass. |
| `manual-recovery-admin` | verification | **never** | Same as above. |
| `ak-outpost-…-api` | api | never | The embedded outpost's own token. Expected; leave it. |

### Resolved 2026-08-07 — both permanent recovery tokens DELETED

`recovery-admin` and `manual-recovery-admin` were **deleted on the operator's
explicit instruction**, ahead of the break-glass account being armed. The table
above is kept as the measured record of what existed; live state is now:

| Token | Status |
| --- | --- |
| `recovery-admin` | **deleted 2026-08-07** |
| `manual-recovery-admin` | **deleted 2026-08-07** |
| `iw-admin-token` | **kept — see below** |
| `ak-outpost-…-api` | kept; required by the embedded outpost |

Deleting them did **not** remove the ability to recover. That was checked
before acting, not after:

- `default-recovery-flow` exists and IS bound to the default brand as
  `flow_recovery`, so the ordinary email recovery path is untouched.
- `ak create_recovery_key` still mints one on demand with cluster exec access —
  short-lived and deliberate, which is the pattern the permanent tokens
  displaced.
- The break-glass account (§3) lands with this branch, dormant until armed.

**`iw-admin-token` was deliberately NOT deleted.** It is not merely an admin
token: `sha256(token.key)` is byte-identical to
`infraweaver-console-secret/authentik-token`, so it IS the console's Authentik
credential. Deleting it breaks user provisioning, invitations, group sync, RBAC
assignment, and every WordPress per-site access grant. It remains a permanent
MFA bypass for the entire API surface, and the correct fix is rotation onto a
dedicated service account with an expiry — not deletion. Sequence: create the
service account and its token, reseed OpenBao, redeploy the console, verify a
grant/revoke round-trip, then revoke the old token. Until that is done this is
an accepted and recorded risk, not an oversight.

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.core.models import Token
for t in Token.objects.all():
    print(t.identifier, str(t.intent), "expiring=", t.expiring, t.expires,
          t.user.username if t.user else None)
PY
```

---

## 11. Related

- `kubernetes/platform/authentik/manifests/blueprints/README.md` — the staged
  MFA rollout this document gates, and the acceptance checks for each stage.
- `docs/BACKUP-AND-RESTORE-RUNBOOK.md` — T2 restore procedures.
- `docs/compliance/` — the ISMS pack. This document is the operational
  procedure behind the emergency-access control; the incident-response plan and
  access-control policy there should cross-reference it, and the access-review
  procedure is the natural place to schedule the §7 drills. *(Owned by the WP7
  documentation package; no changes were made to that tree from here.)*
