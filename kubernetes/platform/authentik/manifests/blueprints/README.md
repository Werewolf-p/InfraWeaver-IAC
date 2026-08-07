# Authentik blueprints — MFA enforcement (WP11 / GAP-C5)

Authentik is the single lock on every admin surface on this platform: ArgoCD,
the console, Grafana, Longhorn, OpenBao, TrueNAS, the Traefik dashboard. Until
this directory existed, its flow and stage configuration lived only inside its
PostgreSQL database — nothing in git said what that lock does.

Measured read-only against the live instance on **2026-08-07**:

| Fact | Value |
| --- | --- |
| Enrolled MFA devices, all classes (totp/webauthn/static/duo/sms/email) | **0** |
| Authenticator-validation stage bound to the authentication flow | yes, order 30 |
| That stage's `not_configured_action` | **`skip`** |
| Superusers | 1 (`admin`) |
| Active human accounts | 6 |

Zero devices plus `skip` means the stage never challenges anyone. The lock is
present in shape and absent in effect: **today, one password opens everything.**

## How blueprints actually reach Authentik here

Two mechanisms in series. Both must be satisfied or a file is decorative.

1. **ArgoCD → ConfigMap.** `kubernetes/bootstrap/app-authentik-manifests.yaml`
   syncs `kubernetes/platform/authentik/manifests` as a plain directory source.
   That source is non-recursive by default, so this subdirectory is only seen
   because that Application carries `directory.recurse: true`. ArgoCD reads
   `*.yaml`, `*.yml` and `*.json` only — which is why the deferred files below
   end in `.DEFERRED`.
2. **Helm values → volume mount.** The authentik chart mounts a ConfigMap into
   the **worker** pod at `/blueprints/mounted/cm-<configmap-name>/` only if the
   ConfigMap is named in `blueprints.configMaps` in `../../values.yaml`. The
   worker's discovery task then registers each `.yaml` under `/blueprints/` as
   a `BlueprintInstance` and applies it. A ConfigMap that exists in the
   namespace but is absent from that list is never mounted and never applied.

Verify both ends:

```bash
kubectl get deploy -n authentik authentik-worker -o json \
  | jq -r '.spec.template.spec.containers[0].volumeMounts[].mountPath' | grep blueprints
kubectl exec -n authentik deploy/authentik-worker -c worker -- ls -R /blueprints/mounted
```

## Files

| File | Mounted? | What it is |
| --- | --- | --- |
| `00-break-glass-account.yaml` | yes | Dormant local recovery superuser. Ships inactive and password-less; armed by hand per `docs/BREAK-GLASS.md`. |
| `10-authentication-current-state.yaml` | yes | Verified no-op export of the live authentication flow, its MFA stage and its three stage bindings. GAP-C5 evidence. |
| `20-mfa-enrollment-optional.yaml` | yes | Defines the group-scopable validation stage. Bound to no flow, so it changes no login. |
| `30-mfa-required-platform-admins.yaml.DEFERRED` | **no** | Stage 4. The enforcement flip, scoped to `platform-admins`. |
| `40-mfa-required-all-users.yaml.DEFERRED` | **no** | Stage 5. Widens enforcement to everyone. |
| `50-unbound-application-policies.yaml.DEFERRED` | **no** | Backfills access policies onto the six live applications that have none. Not MFA; separate decision. |

Enabling any `.DEFERRED` file takes **two** deliberate acts — rename off
`.DEFERRED`, and add its ConfigMap name to `blueprints.configMaps` in
`../../values.yaml`. One accidental rename cannot arm anything.

## Why the current-state export is a no-op

Every attribute in `10-authentication-current-state.yaml` was read back from
the live objects with `ak shell` and compared field by field before it was
written. `state: present` only writes the attributes an entry declares, so an
entry whose declared attributes all equal the live values changes nothing.
Re-check at any time:

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.flows.models import Flow, FlowStageBinding
from authentik.stages.authenticator_validate.models import AuthenticatorValidateStage
f = Flow.objects.get(slug="default-authentication-flow")
print(f.name, f.title, f.designation, f.authentication, f.policy_engine_mode,
      f.compatibility_mode, f.denied_action, f.layout)
s = AuthenticatorValidateStage.objects.get(name="default-authentication-mfa-validation")
print(s.not_configured_action, s.device_classes, list(s.configuration_stages.all()),
      s.last_auth_threshold, s.webauthn_user_verification)
for b in FlowStageBinding.objects.filter(target=f).order_by("order"):
    print(b.order, b.stage.name, b.evaluate_on_plan, b.re_evaluate_policies,
          b.policy_engine_mode, b.invalid_response_action)
PY
```

## The remaining human steps, in order

Do not reorder these. The order is what prevents the only administrator from
being locked out of the identity provider that fronts every other admin
surface.

### Stage 2 — arm and verify break-glass (blocking)

Follow `docs/BREAK-GLASS.md` end to end. Stage 4 must not be attempted until
the break-glass account has been armed **and a real login through it has been
observed**, because an unexercised break-glass procedure is a hope, not a
control.

### Stage 3 — enrol the platform admin

Enrollment already works; nothing needs deploying. Sign in as `admin` and
visit:

```
https://auth.<BASE_DOMAIN>/if/user/#/settings;page-mfa
```

Enrol **two** factors — a TOTP app and a WebAuthn authenticator, or TOTP plus
static backup codes. One factor plus one break-glass account is a single point
of failure with extra steps. Then confirm the count moved off zero:

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.stages.authenticator_totp.models import TOTPDevice
from authentik.stages.authenticator_webauthn.models import WebAuthnDevice
from authentik.stages.authenticator_static.models import StaticDevice
for cls in (TOTPDevice, WebAuthnDevice, StaticDevice):
    print(cls.__name__, [(d.user.username, d.confirmed) for d in cls.objects.all()])
PY
```

A device row with `confirmed=False` is a half-finished enrollment and will not
satisfy a challenge. Do not proceed on one.

### Stage 4 — the flip, `platform-admins` only

Preconditions, all of them:

- [ ] break-glass armed **and** a successful login through it observed (stage 2)
- [ ] at least one `confirmed=True` device for every member of `platform-admins`
- [ ] a second, already-authenticated browser session held open in another
      profile or window, and left open for the whole procedure
- [ ] you can reach `kubectl exec` on this cluster right now — verified, not assumed

Then:

1. `git mv 30-mfa-required-platform-admins.yaml.DEFERRED 30-mfa-required-platform-admins.yaml`
2. Add `authentik-blueprint-mfa-required-admins` to `blueprints.configMaps` in
   `../../values.yaml`.
3. PR → merge to `main` → let ArgoCD sync. The worker restarts to pick up the
   new mount; wait for it to be `Running` before testing.
4. Confirm the blueprint applied cleanly — **status must be `successful`, not
   `error`**:
   ```bash
   kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
   from authentik.blueprints.models import BlueprintInstance
   for b in BlueprintInstance.objects.exclude(status="successful"):
       print(b.name, b.path, b.enabled, b.status)
   PY
   ```
5. Confirm the flow now has two validation stages and the right policy on each:
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
   Expect order 25 with `(platform-admins, False)` and order 30 with
   `(platform-admins, True)`, and `eval_on_plan=False, re_eval=True` on both.
   If `eval_on_plan` is `True` anywhere, the policy evaluates before anyone has
   identified, the stage is dropped from the plan, and **MFA is silently not
   enforced** — it will look fine and challenge nobody.
6. In a fresh incognito window, sign in to `https://argocd.int.<BASE_DOMAIN>`
   as the admin. A second factor must be demanded. If it is not, stop and
   re-check step 5 rather than assuming propagation delay.
7. In another incognito window, sign in as the break-glass account. It must
   **not** be challenged — it is not in `platform-admins`. That is the escape
   hatch working.
8. Only now close the session you held open in the preconditions.

Rollback is in the header of `30-mfa-required-platform-admins.yaml.DEFERRED`.
Blueprint entries are not reverted by removing the blueprint; the bindings must
also be deleted in the admin UI.

### Stage 5 — widen to all users, after at least one week

`40-mfa-required-all-users.yaml.DEFERRED`, plus the companion edit to file 10
described in its header. Do not skip that edit or the two blueprints will fight
over the order-30 binding on every run.

## Two things MFA on this flow does not cover

Say both of these out loud before claiming the gap is closed.

- **API tokens bypass it entirely.** Four non-expiring Authentik tokens exist
  today, including `iw-admin-token` (the console's admin token) and two
  recovery tokens for `admin` (`recovery-admin`, `manual-recovery-admin`). A
  recovery token URL logs its user in through the *recovery* flow, which has no
  validation stage. Anyone holding one of those URLs bypasses every MFA control
  in this directory. Inventory and rotate them — see `docs/BREAK-GLASS.md`.
- **`kubectl exec` into the authentik pod is unconditional admin.** Anyone who
  can reach the cluster API as a sufficiently privileged principal can mint a
  recovery key or edit a stage. MFA on the login flow raises the floor for
  browser access; it does not change that ceiling.

## Unbound applications

Thirteen applications have no policy binding and therefore admit every
authenticated user. Six are live. Details, severity and the remediation
blueprint are in `50-unbound-application-policies.yaml.DEFERRED`. Current
count:

```bash
kubectl exec -i -n authentik deploy/authentik-server -c server -- ak shell <<'PY'
from authentik.core.models import Application
from authentik.policies.models import PolicyBinding
u = [a.slug for a in Application.objects.all().order_by("slug")
     if not PolicyBinding.objects.filter(target=a.pbm_uuid).exists()]
print(len(u), u)
PY
```
