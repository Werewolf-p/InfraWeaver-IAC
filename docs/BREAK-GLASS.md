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
> armed and never been exercised. Re-measured on the live Authentik database
> on 2026-08-07 evening: `break-glass False True ['authentik Admins']`. Until
> §3 and §7 have both been completed and logged, this document describes an
> intention, not a control. **MFA enforcement (WP11 stage 4) must not be
> attempted before then.**
>
> §3 is written as a ten-step operator runbook for one sitting of about twenty
> minutes; §11 is the MFA enforcement procedure it gates, including its
> rollback. Both are for a human at a real terminal — `ak changepassword` is
> interactive, and the password must land somewhere no agent can write.

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

**One sitting, about 20 minutes, ten steps.** It cannot be delegated to an
agent: `ak changepassword` is interactive, and the password has to land in an
offline store that nothing on this platform can write to.

> `u.ak_groups` is **deprecated** in authentik 2026.5.6 and prints a wall of
> warning JSON. Every query below uses `u.groups`. Same answer, no noise.

**Have ready before you start**

- A terminal with `export KUBECONFIG=~/.kube/config-platform-productie` and
  working `kubectl` — verify with `kubectl get pods -n authentik`.
- A browser you can open a **fresh private/incognito window** in, in a profile
  with **no existing Authentik session**.
- An **offline** password manager (local KeePassXC, an OS keychain) on a device
  that can authenticate **without** Authentik. Not `bitwarden.example.com`
  (§8 forbids it), not any cloud vault whose login depends on this platform.
- Pen, paper, an envelope.

### Step 1 — Pre-flight: confirm the dormant state

```bash
export KUBECONFIG=~/.kube/config-platform-productie
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.core.models import User
u = User.objects.filter(username="break-glass").first()
print(u, u and u.is_active, u and u.is_superuser, u and [g.name for g in u.groups.all()])
PY
```

**Done when** the last line reads exactly:

```
break-glass False True ['authentik Admins']
```

That was the measured live state at 2026-08-07 18:14 UTC. If `is_active` is
already `True`, **someone armed it before you** — stop, and establish when and
by whom (the Step 7 query, run with `action="login"` and again with
`action="model_updated"`) before going any further.

### Step 2 — Generate the password (in the offline vault, not in a shell)

In the offline password manager create the entry **"InfraWeaver break-glass"**
and use its generator: **at least 32 characters, fully random**. Do not compose
one. **Save the entry first**, so a mistype at the prompt can be retried from
the stored value rather than from memory.

If you must use a shell instead: `openssl rand -base64 32`. The command line
holds no secret, but the *output* stays in terminal scrollback — clear it when
you are done with `clear && printf '\e[3J'`.

**Done when** the password exists in the offline vault entry.

### Step 3 — Set the password (interactive)

```bash
kubectl exec -it -n authentik deploy/authentik-server -c server -- ak changepassword break-glass
```

Exactly what you will see and type:

```
Changing password for user 'break-glass'
Password:            ← paste the password (nothing echoes — that is normal)
Password (again):    ← paste it again
Password changed successfully for user 'break-glass'
```

- Pasting at these prompts is safe: input is read via `getpass`, never echoed,
  never in shell history.
- `Error: Your passwords didn't match.` → it re-prompts. After three mismatches
  it gives up with `Aborting password change for user 'break-glass' after 3
  attempts` — just run the command again.
- `the input device is not a TTY` → you dropped `-it`, or you are inside a
  non-interactive wrapper. Run it from a real terminal.
- **Never** put the password on the command line or pipe it in. It would land
  in shell history and in the audit log.

**Done when** you saw `Password changed successfully for user 'break-glass'`.

### Step 4 — Activate the account

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.core.models import User
u = User.objects.get(username="break-glass"); u.is_active = True; u.save()
print("active:", u.is_active, "superuser:", u.is_superuser)
PY
```

**Done when** it prints `active: True superuser: True`.

Arming is permanent — the blueprint uses `state: created`, so no later
blueprint run re-disarms it. **One exception worth knowing:** after a disaster
restore onto an empty Authentik database the account comes back **dormant**.
Re-arming is a named restore step. Write that on the envelope contents card in
Step 9.

### Step 5 — Re-verify, including the load-bearing group fact

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.core.models import User
u = User.objects.get(username="break-glass")
print(u.username, u.is_active, u.is_superuser, [g.name for g in u.groups.all()])
print("in platform-admins:", u.groups.filter(name="platform-admins").exists())
PY
```

**Done when** it prints `break-glass True True ['authentik Admins']` and
`in platform-admins: False`.

That `False` **is** the escape hatch, once MFA lands. If it ever prints `True`,
the hatch is shut — remove the membership before doing anything else (§11.4
step 1 has the command).

### Step 6 — §7 Test 1: the real login

1. Open a **fresh private/incognito window**.
2. Go to `https://auth.example.com/if/flow/default-authentication-flow/`
3. Sign in: username `break-glass`, the password from the vault.
4. Confirm you land on the user interface, then open
   `https://auth.example.com/if/admin/` — **the admin interface must render**.
5. Sign out. Close the window.

Today, pre-MFA, no second-factor prompt exists for anyone. You are proving the
credential and the account, not the exemption; the exemption re-check is a
stage-4 step (§11.2 step 7).

- `Request has been denied.` → the account is inactive. Go back to Step 4.
- Wrong-password loop → retype from the vault entry. Do not trust your memory
  of what you pasted in Step 3.

**Done when** `/if/admin/` rendered while signed in as `break-glass`.

### Step 7 — Confirm the login landed in Authentik's event log

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.events.models import Event
for e in Event.objects.filter(action="login").order_by("-created")[:5]:
    print(e.created, e.user.get("username"), e.client_ip)
PY
```

**Done when** the newest row shows `break-glass`, your public IP, and a
timestamp within the last few minutes. **Note that IP and timestamp — they go
in the §9 row.** If no `break-glass` row appears, the login did not happen
against this instance: do not record a PASS.

### Step 8 — §7 Test 2: the recovery-key path (same sitting, ~2 minutes)

```bash
kubectl exec -n authentik deploy/authentik-server -c server -- \
  ak create_recovery_key 5 break-glass 2>/dev/null | grep -v '^{'
```

It prints `https://auth.example.com/recovery/use-token/<key>/`.
**That URL is a live superuser password-equivalent for five minutes.** Do not
paste it into chat, a ticket, or anything that keeps history.

1. Open it in a **new private window** within five minutes. You should land
   authenticated as `break-glass` — this path bypasses the flow engine
   entirely, which is exactly its purpose.
2. Sign out, close the window.
3. Confirm the token was consumed:

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.core.models import Token
print([(t.identifier, str(t.intent)) for t in Token.objects.all()])
PY
```

**Done when** the list contains **exactly two** entries — the
`ak-outpost-…-api` token and `iw-console-api-token`, both intent `api`. That is
the measured live inventory recorded in §10. **No `recovery`-intent token may
remain.** If one does, the URL is still live; delete it — this is the only
mutating fallback in this runbook:

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.core.models import Token
print(Token.objects.filter(intent="recovery").delete())
PY
```

Whether a recovery-key login writes a `login` event row is **not measured**.
Re-run the Step 7 query: if a second `break-glass` row appeared, note it; if
not, note that too. Either observation is honest evidence.

### Step 9 — The envelope and the offline vault

**Inside the envelope, hand-written:**

- `Account: break-glass`
- The password, written carefully — letter-check it against the vault entry.
- `Login: https://auth.example.com/if/flow/default-authentication-flow/`
  `→ then /if/admin/`
- `Armed: <date>. Rotate on any incident use, on envelope-access change, on
  suspicion, and in any case within 12 months.`
- `After a full Authentik DB restore this account returns DORMANT — re-arm per
  docs/BREAK-GLASS.md §3.`
- **A contents card** listing everything else §8 says belongs in the offline
  store, each marked PRESENT or MISSING as of today: OpenBao root token,
  OpenBao unseal key, `kubeconfig`, `talosconfig`, Proxmox `root@pam`, TrueNAS
  `root`. Do not silently omit the missing ones — that card is what makes next
  year's Test 3 meaningful.

**On the envelope:** `InfraWeaver break-glass — sealed <date> — open only per
docs/BREAK-GLASS.md. Opening or unsealing = record a §9 row.`

Store both copies per §8: the sealed envelope somewhere whose access does not
depend on this platform, **and** the offline vault entry. Never in OpenBao,
never in the platform Vaultwarden, never in a repo, ConfigMap, Secret, chat
message or screenshot.

**Done when** both copies exist and the envelope is sealed and dated.

### Step 10 — Record the drill (§9), in git

Replace the two `_(pending)_` rows for Test 1 and Test 2 in §9 with the
templates given there, filling in the date and your client IP, and update the
Test 3 row's follow-up cell. Commit in conventional format — e.g.
`docs: record break-glass arming and first drill rows (BREAK-GLASS §9)` — and
push per the normal flow.

**§3 is DONE when** §9 carries the dated Test 1 row with a real result **and**
the login is visible in Authentik's event log (Step 7). Nothing less counts:
until then this section describes an intention, not a control.

**On rotation and drills.** §8's "rotate on any use" trigger means *incident*
use (§4 Path A step 5). The §7 drills are scheduled exercises and do not by
themselves trigger rotation — otherwise no drill would ever be run, which is
the exact failure §7 exists to prevent.

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

The first run of Tests 1 and 2 happens inside the arming sitting — they are §3
steps 6–8, with the prompts and failure modes spelled out there. Use the
condensed form below for every later run.

**A test only PASSes if you can point at evidence.** For Test 1 that is the
event-log row (username, client IP, timestamp). "It seemed to work" is not a
result; record it as a failure and investigate.

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
anything else (§11.3 is the exact drift check, §11.4 the rollback). Re-run
Test 1 **immediately** after stage 4 lands, not at the next quarter.

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

The expected end state is **exactly two** tokens: `ak-outpost-…-api` and
`iw-console-api-token`, both intent `api` (the live inventory in §10). No
`recovery`-intent token should remain. If one does, the URL is still live —
delete it with the command in §3 step 8.

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

**Templates for the arming sitting.** When §3 completes, replace the Test 1 and
Test 2 rows above with these — filling in the date and the client IP you noted
in §3 step 7 — and update the Test 3 follow-up cell. Do not paste them before
the steps have actually been performed; a pre-filled row is a false record, and
this table is the ISO 27001 A.5.17 / A.8.5 evidence.

```markdown
| <date> | admin | §3 arming + §7 Test 1 — break-glass account login | PASS — armed (password set, is_active=True), private-window login OK, `/if/admin/` rendered, login event recorded for `break-glass` from <client_ip> | Not in `platform-admins` re-verified. Rotate within 12 months or on incident use. Re-run Test 1 immediately after WP11 stage 4 lands (must NOT be challenged) |
| <date> | admin | §7 Test 2 — recovery key path (5-min key for break-glass) | PASS — URL landed authenticated, token consumed, no recovery-intent token remains (verified: only outpost + iw-console-api-token exist) | Next: semi-annual |
| _(pending)_ | | Test 3 — offline store audit | | envelope first sealed <date> with contents card; first audit due <date + 12 months> |
```

A failed attempt that was cleanly rolled back belongs in this table too. That
is auditable evidence; a quietly re-tried one is not.

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
| `iw-admin-token` | **rotated, then deleted 2026-08-07** — see below |
| `iw-console-api-token` | **new 2026-08-07** — the console's credential. Owned by `svc-infraweaver-console`, **expires 2027-08-07** |
| `ak-outpost-…-api` | kept; required by the embedded outpost |

Deleting them did **not** remove the ability to recover. That was checked
before acting, not after:

- `default-recovery-flow` exists and IS bound to the default brand as
  `flow_recovery`, so the ordinary email recovery path is untouched.
- `ak create_recovery_key` still mints one on demand with cluster exec access —
  short-lived and deliberate, which is the pattern the permanent tokens
  displaced.
- The break-glass account (§3) lands with this branch, dormant until armed.

### Resolved 2026-08-07 — `iw-admin-token` ROTATED and deleted

`iw-admin-token` could not simply be deleted: `sha256(token.key)` was
byte-identical to `infraweaver-console-secret/authentik-token`
(`810dbee98572e45e…`, verified again immediately before the rotation), so it
**was** the console's Authentik credential. Deleting it would have broken user
provisioning, invitations, group sync, RBAC assignment and every WordPress
per-site access grant. The prescribed fix — rotation onto a dedicated service
account with an expiry — was carried out in full:

1. Created service account `svc-infraweaver-console`
   (`type=service_account`, member of `authentik Admins`) and token
   `iw-console-api-token`, `intent=api`, **`expiring=True`, expires
   2027-08-07**.
2. Wrote it to OpenBao `secret/platform/infraweaver-console`
   (property `authentik-token`, version 25), preserving all 27 existing keys.
   Note the console's own OpenBao token has `["list","read"]` on that path and
   **cannot** rewrite its own credentials — deliberate, and correct; the write
   needs the root token per `OPENBAO-OPERATIONS.md`.
3. Forced the ExternalSecret to resync and confirmed the Kubernetes Secret
   carried the new value (`b667ca9364a303e1…`), then restarted the console.
4. **Verified a grant/revoke round-trip from inside a running console pod,
   using its live `AUTHENTIK_TOKEN`** — whoami → `svc-infraweaver-console`;
   list users 200; list groups 200; create group 201; add user 204; remove
   user 204; delete group 204.
5. Deleted `iw-admin-token`. Re-checked afterwards: the console's Authentik
   calls still return 200, the portal returns 200, all Applications are
   Synced/Healthy and all 28 ExternalSecrets are Ready.

What this bought: the permanent, never-expiring MFA bypass on `admin`'s own
identity is gone. A second-order win — the console's credential is no longer
owned by a human. The offboard route deletes tokens whose `token.user` matches
the user being offboarded, so offboarding `admin` would previously have
decapitated the console; it no longer can.

**Two things this did NOT fix — do not read it as more than it is:**

- **The service account is still a superuser** (member of `authentik Admins`).
  Scoping it to the exact permission set the console needs is the remaining
  least-privilege work; it was not attempted here because under-granting
  silently breaks provisioning, and that trade needs a deliberate enumeration
  of every Authentik call the console makes.
- ~~**The token expires 2027-08-07 and nothing watches that date.**~~ **Closed
  2026-08-07** — something watches it now; see the expiry watch below. There is
  still no rotation *automation*: when the alert fires, a human does the
  rotation. What changed is that the date can no longer pass unnoticed.

**Expiry watch — DECIDED 2026-08-07, SHIPPED (backlog P1.1).** Of the three
candidates — a Prometheus alert on the token's `expires` date, a calendar entry,
or rotation automation — the **measured Prometheus alert** was chosen and is in
place. The other two were not: a calendar entry is a claim rather than a
control, and rotation automation would need a standing write credential on
`secret/platform/infraweaver-console`, which is exactly the privilege step 2
above deliberately withheld from the console.

"Measured" is the whole point, and the reason this closes the gap rather than
renaming it. The console reads its **own** token back from Authentik on every
scrape and exports the remaining lifetime, so the signal also catches early
revocation, deletion, a rename, and a rotation that quietly did not happen —
none of which a hardcoded date could ever see. The artifacts:

| Piece | Where |
| --- | --- |
| Lookup + exposition | console `src/lib/secrets/authentik-token.ts`, `authentik-token-metrics.ts`, served at `/api/platform/metrics` |
| Scrape | the existing `wordpress-connector-metrics` ServiceMonitor, every 300s |
| Alerts | `kubernetes/monitoring/alerts/authentik-token.yaml` — warning at 60d, critical at 14d, warning when the expiry becomes unobservable |

Thresholds are 60d/14d, not the 30d/7d used for the OpenBao token next door.
That is deliberate: OpenBao's token is renewed by a CronJob, so its warning
means "an automated loop needs a nudge". This one has no automation, and
replacing it needs the OpenBao **root** token (step 2 above) — scheduled
operator time with a credential that lives offline. Two months' notice, not one.

> **ROTATION INVARIANT — a replacement token MUST keep the identifier
> `iw-console-api-token`.** The lookup matches that identifier exactly, and
> deliberately so: reporting a *different* token's expiry would be worse than
> reporting none. Mint the replacement under any other name and the console
> reports `lookup_ok 0` — the expiry alerts go blind and you get an
> `AuthentikConsoleTokenUnobservable` warning instead of a countdown, even
> though the new token works perfectly. Rotate the value, keep the name.

**Live token inventory, re-verified 2026-08-07 evening:** exactly two tokens
exist — `ak-outpost-…-api` (api, non-expiring, expected) and
`iw-console-api-token` (api, expiring, 2027-08-07, owner
`svc-infraweaver-console`). `iw-admin-token`, `recovery-admin` and
`manual-recovery-admin` are all gone from the live database. That two-token
list is the baseline §3 step 8 and §7 Test 2 check against.

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.core.models import Token
for t in Token.objects.all():
    print(t.identifier, str(t.intent), "expiring=", t.expiring, t.expires,
          t.user.username if t.user else None)
PY
```

---

## 11. MFA enforcement (WP11 stage 4) — the procedure this document gates

**Hard gate: nothing in this section may start until §9 carries the dated
Test 1 row.** Zero MFA devices are enrolled platform-wide (re-verified
2026-08-07 evening: TOTP, WebAuthn and static device tables are all empty) and
`platform-admins` has exactly one member. Flipping enforcement before the
escape hatch is armed and exercised locks the operator out of Authentik — and
therefore out of ArgoCD, the console, Grafana, Longhorn, OpenBao and every
other admin surface, all at once.

This section lives here, and not only in the blueprints README, because its
single most important step is a break-glass re-verification.

### 11.1 What the two deferred blueprints actually do

Both are ConfigMaps invisible to the cluster behind **two independent gates**:
the `.DEFERRED` filename suffix (ArgoCD's directory source reads only
`*.yaml|*.yml|*.json`) and absence from `blueprints.configMaps` in
`kubernetes/platform/authentik/values.yaml` (an unlisted ConfigMap is never
mounted into the worker, so it is never applied). Both must be opened by hand.
One accidental rename arms nothing.

**`30-mfa-required-platform-admins.yaml.DEFERRED` — stage 4, the enforcement
flip.** Three blueprint entries:

1. Binds the existing-but-unbound stage `platform-admin-mfa-validation`
   (defined by the already-applied `20-mfa-enrollment-optional.yaml`:
   `not_configured_action: configure`, device classes totp/webauthn/static,
   `last_auth_threshold: seconds=0`, i.e. challenged on every login) into
   `default-authentication-flow` at **order 25** — after identification (10),
   before the inert original (30) — with `evaluate_on_plan: false` and
   `re_evaluate_policies: true`.
2. Attaches a **group policy binding** (`platform-admins`, `negate: false`) to
   that order-25 binding, so only members reach it.
3. Attaches the **same group check, negated**, to the existing inert order-30
   binding, so members skip it.

Net effect: exactly one validation stage runs per user. `platform-admins`
members get enrol-or-challenge; everyone else keeps today's behaviour (the
order-30 stage with `not_configured_action: skip`, which challenges nobody).

Two subtleties the file's own header insists on, both verified against source:

- The `evaluate_on_plan: false` / `re_evaluate_policies: true` pair is what
  makes the group check evaluate against the *identified* user instead of
  `AnonymousUser`. Flip either one and MFA becomes **silently inert while
  looking configured**.
- Entry 3's `!Find` deliberately targets
  `authentik_policies.policybindingmodel` (`pbm_uuid`), not the flow stage
  binding (`fsb_uuid`). Target the wrong model and the binding attaches to
  nothing — silently.

**`40-mfa-required-all-users.yaml.DEFERRED` — stage 5, widen to everyone.**
Three `state: absent` entries: delete the group binding on order 25 (so the
stage applies to every user), delete the negated binding on order 30, and
delete the order-30 stage binding itself (otherwise everyone is challenged
twice). **Required companion edit:** remove the
`binding-authentication-mfa-validation` entry from
`10-authentication-current-state.yaml` **in the same commit**, or the two
blueprints will recreate and delete the order-30 binding against each other on
every run, forever. Stage 5 is out of scope until stage 4 has been live and
quiet for at least a week and every human account is enrolled.

### 11.2 The sequence: stage 3 → stage 4

**Stage 3 — enrol the admin.** No deploy is needed; enrolment already works.

1. As `admin`: `https://auth.example.com/if/user/#/settings;page-mfa` → enrol
   **two** factors (TOTP app plus a WebAuthn authenticator, or TOTP plus static
   codes). One factor is a single point of failure with extra steps.
2. Verify, and accept only `confirmed=True`:

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.stages.authenticator_totp.models import TOTPDevice
from authentik.stages.authenticator_webauthn.models import WebAuthnDevice
from authentik.stages.authenticator_static.models import StaticDevice
for cls in (TOTPDevice, WebAuthnDevice, StaticDevice):
    print(cls.__name__, [(d.user.username, d.confirmed) for d in cls.objects.all()])
PY
```

**Done when** at least one device shows `('admin', True)`, ideally in two
classes. A `confirmed=False` row is a half-finished enrolment; it will not
satisfy a challenge. Do not proceed on one.

**Stage 4 preconditions — all four, verified rather than assumed:**

- [ ] §9 carries the dated Test 1 row (§3 complete)
- [ ] a `confirmed=True` device for **every** member of `platform-admins`
      (measured membership: `admin` only)
- [ ] a second, already-authenticated admin browser session held open in
      another profile or window **for the whole procedure**
- [ ] `kubectl exec` into the authentik pod works **right now** — re-run the
      stage 3 query as the proof

**The flip (one PR):**

1. `git mv kubernetes/platform/authentik/manifests/blueprints/30-mfa-required-platform-admins.yaml.DEFERRED kubernetes/platform/authentik/manifests/blueprints/30-mfa-required-platform-admins.yaml`
2. Add `authentik-blueprint-mfa-required-admins` to `blueprints.configMaps` in
   `kubernetes/platform/authentik/values.yaml` — the commented placeholder is
   already at the end of that list.
3. PR → merge → ArgoCD sync. The worker restarts to pick up the new mount; wait
   for Running: `kubectl get pods -n authentik -l app.kubernetes.io/component=worker`
4. Confirm the blueprint applied:

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.blueprints.models import BlueprintInstance
for b in BlueprintInstance.objects.exclude(status="successful"):
    print(b.name, b.path, b.enabled, b.status)
PY
```

   **TRAP — measured baseline.** Four BlueprintInstances are **already** in
   `error` before any MFA change, as of 2026-08-07 evening: `ArgoCD and OpenBao
   OAuth2 Setup`, `Platform Users Setup`, `Forward-Auth (auto-generated)` and
   `authentik Bootstrap`. Their cause has not been diagnosed. Seeing them is
   **not** a stage-4 failure, and clearing them is separate work. **Done when**
   `InfraWeaver MFA Required — platform-admins` is absent from this list, and
   only those four pre-existing errors remain.

5. Confirm the flow shape:

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.flows.models import Flow, FlowStageBinding
from authentik.policies.models import PolicyBinding
f = Flow.objects.get(slug="default-authentication-flow")
for b in FlowStageBinding.objects.filter(target=f).order_by("order"):
    pbs = [(p.group.name if p.group else p.policy.name, p.negate)
           for p in PolicyBinding.objects.filter(target=b.pbm_uuid)]
    print(b.order, b.stage.name, "eval_on_plan=", b.evaluate_on_plan,
          "re_eval=", b.re_evaluate_policies, pbs)
PY
```

   **Done when** order 25 `platform-admin-mfa-validation` shows
   `[('platform-admins', False)]`, order 30 shows `[('platform-admins', True)]`,
   and **both** carry `eval_on_plan= False re_eval= True`. If `eval_on_plan` is
   `True` anywhere, MFA is silently **not** enforced — it will look correct and
   challenge nobody. Fix that before any login test.

6. **Positive test.** Fresh incognito → `https://argocd.int.example.com` →
   sign in as `admin`. A second factor **must** be demanded. If it is not:
   stop, re-run step 5. Do not assume propagation delay, and do not record
   progress against A.8.5.

7. **The critical re-verification — the escape hatch still opens.** Re-run §7
   Test 1: another fresh incognito window, sign in as `break-glass`. It must
   land on `/if/admin/` **with no second-factor challenge** — it is not in
   `platform-admins`, so it never traverses order 25. Then confirm the login
   event (§3 step 7 query) and add a fresh §9 row noting "post-stage-4: not
   challenged".

8. Only now close the held-open session.

### 11.3 Drift check — run any time, and always as part of 11.2 step 7

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.core.models import User
u = User.objects.get(username="break-glass")
print("in platform-admins:", u.groups.filter(name="platform-admins").exists())
PY
```

**Must print `False`.** `True` means the hatch has been scoped into enforcement
— i.e. shut. Re-run the 11.2 step-5 flow-shape query as well: the hatch depends
on **both** facts, group membership *and* the negate/False pairing on orders 25
and 30.

### 11.4 Abort and rollback — if break-glass IS challenged, or anything else goes wrong

Do this **while the held-open session and `kubectl exec` both still work**.
That is precisely why the preconditions demand them.

1. If drift is the cause (`in platform-admins: True`), remove the membership
   and re-test — that alone may reopen the hatch:

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.core.models import User, Group
Group.objects.get(name="platform-admins").users.remove(User.objects.get(username="break-glass"))
print("removed; in platform-admins:",
      User.objects.get(username="break-glass").groups.filter(name="platform-admins").exists())
PY
```

2. Roll back the flip on the git side: rename the file back to `.DEFERRED`,
   remove `authentik-blueprint-mfa-required-admins` from
   `blueprints.configMaps`, commit the revert, let ArgoCD sync.
3. **Removing the blueprint does not revert what it created.** The live objects
   must be deleted too. In the admin UI: Flows → `default-authentication-flow`
   → Stage Bindings. The guaranteed path, which works with zero browser access:

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.flows.models import Flow, FlowStageBinding
from authentik.policies.models import PolicyBinding
f = Flow.objects.get(slug="default-authentication-flow")
b25 = FlowStageBinding.objects.filter(target=f, order=25).first()
if b25:
    print("del order-25 policy bindings:", PolicyBinding.objects.filter(target=b25.pbm_uuid).delete())
    print("del order-25 stage binding:", b25.delete())
b30 = FlowStageBinding.objects.filter(target=f, order=30).first()
if b30:
    print("del order-30 policy bindings:", PolicyBinding.objects.filter(target=b30.pbm_uuid).delete())
PY
```

   This restores the pre-flip shape: order 30 present, unpoliced, `skip`. Do
   the git rollback **first**, or in the same sitting — otherwise the
   still-mounted blueprint re-applies the bindings on its next run.
4. Verify: the 11.2 step-5 query shows no order-25 binding and no policy
   bindings on order 30; a normal `admin` login works password-only again; §7
   Test 1 passes.
5. Record the failed attempt and the rollback as a §9 row.

**Also abort if:** the blueprint lands in `error` (fix it before testing any
login — the flow may be half-modified, so check the shape first); the worker
never mounts the ConfigMap
(`kubectl exec -n authentik deploy/authentik-worker -c worker -- ls -R /blueprints/mounted`
— gate 2 was forgotten); or the held-open session is lost mid-procedure
(recover access first via `ak create_recovery_key 30 break-glass`, §4 Path B —
prefer `break-glass` over `admin` to keep the audit trail honest).

### 11.5 Traps and abort conditions, consolidated

1. **Order is the safety mechanism.** §3 → stage 3 → stage 4 → re-verify
   break-glass. Never reorder. The failure mode of reordering is total loss of
   admin access on every surface at once.
2. **There is zero shame in aborting.** Neither §7 test changes any
   configuration, and stage-4 rollback is fully specified in §11.4. Record
   failed attempts in §9 — that is evidence, not embarrassment.
3. **`u.ak_groups` is deprecated** in authentik 2026.5.6 and prints a wall of
   warning JSON. Use `u.groups`; the answer is the same.
4. **Four BlueprintInstances are already in `error`** before any MFA change
   (11.2 step 4). Baseline them. Only a non-`successful` `InfraWeaver MFA
   Required — platform-admins` is a stage-4 failure.
5. **`evaluate_on_plan` is the silent-inert switch.** If the flow-shape query
   shows `eval_on_plan= True` on orders 25 or 30, MFA looks configured and
   challenges nobody — this platform's signature failure mode, configured ≠
   succeeded, applied to authentication.
6. **Blueprint removal does not revert blueprint entries.** Rollback is a git
   revert **and** live-object deletion (§11.4 step 3), in the same sitting.
7. **Recovery-key URLs are password-equivalents.** Never in chat, tickets or
   anything with history. Mint for `break-glass`, not `admin`. Always confirm
   consumption afterwards — expected end state is the outpost token plus
   `iw-console-api-token`, and nothing else.
8. **The offline vault must not depend on the platform** — not Vaultwarden
   (`bitwarden.example.com`, GAP-H6), not anything behind Authentik SSO.
9. **A drill is not incident use** for rotation purposes. Incident use of
   break-glass triggers immediate rotation (§8); scheduled drills do not.
10. **After any disaster restore onto an empty Authentik DB, break-glass
    returns dormant** (`state: created` recreates it inactive). The envelope
    contents card carries this; do not let a future restore silently disarm the
    hatch.
11. **`kubectl` is the real ceiling either way.** MFA raises the floor for
    browser access; anyone with `kubectl exec` on the authentik pod is
    unconditionally an Authentik administrator. Treat the kubeconfig with the
    same seriousness as the envelope.

---

## 12. Related

- `kubernetes/platform/authentik/manifests/blueprints/README.md` — the staged
  MFA rollout this document gates, and the acceptance checks for each stage.
- `docs/BACKUP-AND-RESTORE-RUNBOOK.md` — T2 restore procedures.
- `docs/compliance/` — the ISMS pack. This document is the operational
  procedure behind the emergency-access control; the incident-response plan and
  access-control policy there should cross-reference it, and the access-review
  procedure is the natural place to schedule the §7 drills. *(Owned by the WP7
  documentation package; no changes were made to that tree from here.)*
