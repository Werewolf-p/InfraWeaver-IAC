# infraweaver-foyer (GitOps)

ArgoCD-managed manifests for **Foyer** — the customer-facing WordPress SSO
portal. A signed-in client sees the WordPress sites they have access to, the
role they hold on each, and clicks through to the site already authenticated.

App source: `InfraWeaver-platform/apps/infraweaver-foyer`.

```
infraweaver-foyer/
├── catalog.yaml          # catalog metadata (namespace, ingress host, OpenBao keys)
├── base/                 # environment-agnostic — changes rarely
│   ├── kustomization.yaml
│   ├── serviceaccount.yaml
│   ├── rbac.yaml         # 2 verbs, 3 named ConfigMaps, 1 namespace
│   ├── externalsecret.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingressroute.yaml # public host, lives in the `traefik` namespace
│   ├── networkpolicy.yaml
│   ├── poddisruptionbudget.yaml
│   └── policyexception-automount.yaml
└── overlays/
    └── prod/
        └── kustomization.yaml   # ← THE param layer (image tag, host, CIDR)
```

> **Status: this bundle has never been deployed and cannot be yet.** No Foyer
> container image exists in the registry. See [§Go-live](#go-live).

---

## Why no dedicated namespace

Foyer runs in **`infraweaver-console`**, alongside the console. That looks like
the less isolated choice; measured against how this cluster actually enforces
isolation, it is the *more* secure one.

**The deciding fact.** `kubernetes/core/psa/namespace-labels.yaml` says, in its
own header:

> ⚠️ SINGLE SOURCE OF TRUTH: This file is the ONLY place PSA labels are set.
> Individual apps must NOT include Namespace resources with PSA labels.

Every Pod Security Admission level *and* the `infraweaver.io/type: catalog-app`
label live in that one file — and that label is the `namespaceSelector` on
**every** Kyverno policy in `kubernetes/core/kyverno/manifests/`
(`require-non-root`, `require-resource-limits`, `require-pod-probes`,
`require-seccomp-profile`, `disallow-privilege-escalation`,
`require-drop-all-capabilities`, `no-latest-tag`, …). A namespace this package
created would therefore be born:

- with **no PSA enforcement at all** (an unlabelled namespace defaults to
  `privileged`), versus `enforce: baseline` / `audit: restricted` /
  `warn: restricted` which `infraweaver-console` already carries; and
- **outside the match set of every Kyverno policy**, so not one of them would
  even audit the pod.

Adding those labels means editing `kubernetes/core/psa/namespace-labels.yaml`,
which this package does not own. Choosing the console namespace buys the
correct PSA level, full Kyverno coverage, and the governed LimitRange
(`kubernetes/core/limitranges/namespace.yaml`: `max` 2 CPU / 2Gi,
`maxLimitRequestRatio.memory` 10, and deliberately **no ResourceQuota**, so
nothing here can be quota-blocked) on day one, with no cross-package edit.

**What co-tenancy does *not* cost.** The obvious objection is that
`infraweaver-console` holds the crown jewels: `infraweaver-console-secret`
(GitHub PAT, OpenBao token, IWSL signing keys, `NEXTAUTH_SECRET`) and a
ServiceAccount with cluster-wide `get/list/watch` on secrets and `pods/exec`.
None of that is reachable from a compromised Foyer pod, because **Secrets are
protected by RBAC, not by namespace membership**:

| Isolation mechanism | Namespace-scoped? | Foyer's position |
|---|---|---|
| Secret access | **No** — RBAC | Foyer's SA has *zero* `secrets` verbs. Sharing the namespace grants it nothing. |
| ServiceAccount identity | Per-SA | Own SA (`infraweaver-foyer`), own Role. Never the console's. |
| NetworkPolicy | Per-pod-selector | Own default-deny + allow-list, selecting `app=infraweaver-foyer` only. |
| PSA / Kyverno | **Yes** — per namespace | ✅ inherited correctly. A new namespace would inherit *nothing*. |
| ResourceQuota | Per namespace | None in this namespace, by design (HPA headroom). |

The one real cost is that a namespace-scoped `get secrets` grant held by a
future third workload in this namespace would see both apps' secrets. That is a
grant nobody has today, and it is a reviewable event.

**Two incidental wins:** the RBAC for the three ConfigMaps is a *local* Role
rather than a cross-namespace one, and Foyer can reference the console
package's ESO-synced `registry-pull-secret` instead of needing its own copy of
that ExternalSecret in a fresh namespace.

**If a dedicated namespace is wanted later**, it is a two-part change, and the
first part must land first:

```yaml
# kubernetes/core/psa/namespace-labels.yaml  — add this block
apiVersion: v1
kind: Namespace
metadata:
  name: infraweaver-foyer
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
    infraweaver.io/type: catalog-app
    app.kubernetes.io/name: infraweaver-foyer
```

…then flip `namespace:` here, make the ConfigMap Role cross-namespace (it
already names `infraweaver-console` explicitly, so only the RoleBinding's
subject namespace changes), and add a `registry-pull-secret` ExternalSecret.

---

## RBAC — every grant, and the line of code that needs it

Derived by enumerating the `@kubernetes/client-node` calls in the app, not by
copying a neighbour:

```
grep -rn "listNamespaced\|readNamespaced\|patchNamespaced\|createNamespaced\|deleteNamespaced" \
  apps/infraweaver-foyer/src/
```

returns exactly four lines:

| Verb | Resource | Bound to | Code evidence |
|---|---|---|---|
| `get` | `configmaps` | `resourceNames: [infraweaver-foyer-config]`, ns `infraweaver-console` | `src/lib/portal-config.ts:107` — the portal master switch; unreadable ⇒ **disabled**, never open |
| `get` | `configmaps` | `resourceNames: [infraweaver-foyer-rights]`, ns `infraweaver-console` | `src/lib/rights.ts:161` — per-user role projection; unreadable ⇒ neutral chips, access unchanged |
| `get` | `configmaps` | `resourceNames: [infraweaver-wp-manage-snapshots]`, ns `infraweaver-console` | `src/lib/snapshots.ts:75` — WordPress version chip |
| `list` | `apps/deployments` | ns `wordpress` | `src/lib/sites.ts:161` — `listFleet()` |

Nothing else. No Secrets, no `pods/exec`, no Services (an explicit design
decision documented at `src/lib/sites.ts:12-15`), no writes anywhere.

**Three things worth stating plainly rather than implying:**

1. **The third ConfigMap is real.** `infraweaver-wp-manage-snapshots` is not in
   the plan's two-ConfigMap ops note, but `snapshots.ts:75` reads it. Omitting
   it would not break the portal — it would silently drop every version chip
   while everything else looked healthy.
2. **`list` is not granted on ConfigMaps, on purpose.** `resourceNames` cannot
   restrict a `list` (the request carries no name for the authorizer to match),
   so `list` here would silently be namespace-wide read on the console's entire
   config surface. Foyer reads each map by name; three `get`s is the honest
   expression of that.
3. **The `wordpress` Deployments grant genuinely covers the namespace.** The
   label selector in `listFleet()` is applied by the apiserver *after*
   authorization, so it narrows the result, never the grant. There is no RBAC
   construct that narrows it further. Mitigating: that namespace holds only
   WordPress site workloads; Deployment specs there carry no secret material
   (credentials arrive by `envFrom.secretRef`, whose *values* need a `secrets`
   verb this SA does not have); and the actual visibility decision is made from
   the OIDC `groups` claim, not from this list.

`automountServiceAccountToken: true` is required and deliberate — those four
reads *are* the product. The mitigation is the bounded Role above, not a
missing token. `base/policyexception-automount.yaml` silences the resulting
Kyverno false positive for this workload only.

---

## Pod security

Satisfies PSA `restricted` (the namespace enforces `baseline` and audits/warns
`restricted`, so this clears the enforced bar with room to spare) and every
Kyverno rule that selects `infraweaver.io/type: catalog-app`:

| Control | Value | Policy satisfied |
|---|---|---|
| `runAsNonRoot` / `runAsUser` | `true` / `1001` | `require-non-root` |
| `readOnlyRootFilesystem` | `true` | PSS hardening |
| `allowPrivilegeEscalation` | `false` | `disallow-privilege-escalation` |
| `capabilities.drop` | `["ALL"]` | `require-drop-all-capabilities` |
| `seccompProfile` | `RuntimeDefault` (pod **and** container) | `require-seccomp-profile` |
| requests | `cpu 50m`, `memory 128Mi` | `require-memory-request-and-limit` |
| limits | `cpu 300m`, `memory 384Mi` | `require-resource-limits`; burst ratio 3× (ceiling 8×) |
| probes | startup + readiness + liveness | `require-pod-probes` |
| image tag | pinned, never `:latest` | `no-latest-tag` |

`runAsUser: 1001` matches the `nextjs` user in `Dockerfile.prebuilt`
(`adduser --uid 1001`); a mismatch would make every write to the `emptyDir`s
fail with `EACCES` under `readOnlyRootFilesystem`.

**Probes target `/signin`**, not `/api/my-sites`. `/signin` is `force-dynamic`,
renders server-side, and touches **neither the apiserver nor Authentik** — so an
apiserver blip degrades the *feed* (which `portal-config.ts` and `snapshots.ts`
are both written to survive) without marking every pod Unready and taking the
whole portal down. `/api/my-sites` would be wrong twice over: it reads the
cluster *and* is per-user rate limited. Foyer has no `/api/ping` equivalent to
the console's; adding one in the app repo is a reasonable follow-up.

### Capacity

Measured on the live cluster, 2026-08-07 (`kubectl describe node`):

| Node | Memory requested | Allocatable | Headroom |
|---|---|---|---|
| `talos-prod-cp1` | 19030Mi (92%) | ~20685Mi | ~1655Mi |
| `talos-prod-cp2` | 8358Mi (40%) | ~20895Mi | ~12537Mi |
| `talos-prod-cp3` | 4888Mi (74%) | ~6605Mi | ~1717Mi |

Two replicas × 128Mi = **256Mi of new memory requests**, ~1.2% of cp2's
allocatable. `topologySpreadConstraints` with `whenUnsatisfiable: ScheduleAnyway`
prefers one pod per node; the scheduler's `LeastAllocated` scoring puts the
first on **cp2** (by far the most headroom) and the second on cp3 or cp1, both
of which have >1.6Gi free — so both pods fit even in the worst placement, and
the constraint degrades to co-location rather than Pending if that ever stops
being true. No `priorityClassName`: the customer portal must never evict the
console, which is the tool you fix the cluster with.

---

## Network posture

Default-deny in **both** directions (`infraweaver-foyer-default-deny`), scoped
to `app=infraweaver-foyer` — never `podSelector: {}`, which would also govern
the console's pods in a namespace whose own package already owns a namespace-wide
deny.

The allow-list is four rules:

| Direction | Target | Why |
|---|---|---|
| Ingress | `traefik` ns → pod port **3000** | The only way in. Nothing in-cluster consumes Foyer. |
| Egress | `kube-system` :53 UDP/TCP | DNS |
| Egress | `10.96.0.1/32:443` and `<mgmt CIDR>:6443` | apiserver — the four reads above |
| Egress | `authentik` ns :**9000**/:**9443** | OIDC backchannel, in-cluster |
| Egress | `0.0.0.0/0:443` minus RFC1918 | `idpFetch()` reaching `AUTHENTIK_ISSUER` by its **public** name (discovery, JWKS, refresh, the 15-min userinfo group re-verify), which hairpins through the public edge |

The Authentik rule names **9000/9443**, not 80/443: a NetworkPolicy port matches
the destination *pod* port after Service translation, and getting that wrong on
`authentik-server` is exactly what once broke every SSO front-channel login on
this cluster. `scripts/validate-netpol-ports.sh` gates the class.

The public-egress rule is Foyer's only route off-cluster and excludes every
private range, so it cannot become a path to any other cluster or LAN service.
Foyer talks to no database, no SMTP, no GitHub and no WordPress site — there is
nothing left to narrow.

**Edge:** `base/ingressroute.yaml` lives in the **`traefik`** namespace because
Traefik resolves `tls.secretName` in the IngressRoute's own namespace, and the
public wildcard `platform-wildcard-tls` exists only there. That is the same
pattern `kubernetes/core/registry/registry.yaml` uses. `secure-headers` is
attached (the standard edge posture); **no** `forward-auth`, because Foyer owns
its own session lifecycle — the fail-closed 60-minute group-staleness ceiling
and the session-death recovery in `src/lib/session-guard.ts` are app-side, and a
second, differently-expiring proxy session in front would re-create the
"every page blank" class of bug.

**DNS** is automatic: external-dns runs `sources: [traefik-proxy]` with
`--annotation-filter=external-dns.alpha.kubernetes.io/managed in (true)`, so
the two annotations on the route publish `portal.${BASE_DOMAIN}` to Cloudflare
(proxied) against `--default-targets=203.0.113.10`.

---

## Secrets

ESO + OpenBao, `ClusterSecretStore: openbao`, `deletionPolicy: Retain` — the
console's exact pattern. **No secret value is ever in git.**

OpenBao path: **`secret/platform/infraweaver-foyer`**

```sh
bao kv patch secret/platform/infraweaver-foyer oidc-client-id=infraweaver-foyer
bao kv patch secret/platform/infraweaver-foyer oidc-client-secret=<from Authentik>
bao kv patch secret/platform/infraweaver-foyer nextauth-secret=$(openssl rand -hex 32)
```

> Under `deletionPolicy: Retain`, ESO fails the **entire** secret sync if **any**
> referenced property is missing — the pod then gets no secret at all while
> every individual resource still reports healthy. All three properties are
> therefore also declared in `catalog.yaml` so `scripts/seed-catalog-secrets.sh`
> materialises them on a fresh install.

`nextauth-secret` **must not** be the console's. A shared Auth.js signing key
would make a token minted for one app presentable to the other.

---

## Go-live

Ordered, because the order matters.

1. ~~**Build and push a Foyer image**~~ — **DONE 2026-08-07.**
   `foyerup-20260807-123704`, digest
   `sha256:c6fc689b13d8261a7a0d792d9610fb588d88392d005f73f01ad124ea16bad5bf`,
   pinned in `overlays/prod/kustomization.yaml`.

   Before this, `/v2/infraweaver-foyer/tags/list` returned `NAME_UNKNOWN` — no
   Foyer image had ever been built, so the Deployment could only
   ImagePullBackOff. To rebuild (note: `docker`, not `buildah`, is what is
   actually installed on the build host):
   ```sh
   cd apps/infraweaver-foyer && npm run build   # produces .next/standalone
   docker build -f Dockerfile.prebuilt \
     --build-arg APP_VERSION=foyerup-$(date +%Y%m%d-%H%M%S) \
     -t registry.int.example.com/infraweaver-foyer:<tag> \
     apps/infraweaver-foyer/
   docker push registry.int.example.com/infraweaver-foyer:<tag>
   ```
   Then update the tag in `overlays/prod/kustomization.yaml` — it is pinned in
   exactly one place there.
2. **Create the Authentik application + OIDC provider** with slug
   `infraweaver-foyer`, redirect URI
   `https://portal.<base-domain>/api/auth/callback/authentik`, and a
   `offline_access` scope mapping. Copy the generated client secret into
   OpenBao (above).
3. **Seed OpenBao** (above), confirm `infraweaver-foyer-secret` materialises.
4. **Register the app** — the one-line addition this bundle deliberately does
   **not** make, because `platform.yaml` is a shared repo-root file:
   ```yaml
   # platform.yaml, under catalog.enabled:
       - infraweaver-foyer
   ```
   Without it, `scripts/sync-catalog.sh` will **delete**
   `kubernetes/bootstrap/catalog-infraweaver-foyer-manifests.yaml` on its next
   run (its "disabled apps" loop removes any `catalog-*.yaml` not on that list).
5. **Write side of the two Foyer ConfigMaps.** Foyer is read-only and fails
   closed: with no `infraweaver-foyer-config`, `readPortalConfig()` returns
   `disabledConfig()` and **every route answers 503 for everyone**. The console
   must ship the portal-management card (plan WP-E) and the rights projection
   writer (plan WP-D) or the portal is permanently dark.
6. **Smoke:** a user with one grant sees one card with the right chip; a user
   with zero grants sees the empty state; `/go/<other-site>` → 404; portal off
   → 503 everywhere. Confirm Loki is picking up the `foyer-sso-handoff` lines.

---

## Validate locally

```sh
kubectl kustomize kubernetes/catalog/infraweaver-foyer/overlays/prod   # must render clean
kubectl kustomize kubernetes/catalog/infraweaver-foyer/overlays/prod | grep '\${'   # must be EMPTY
bash scripts/validate-iac.sh
bash scripts/validate-netpol-ports.sh
```

The `grep '\${'` check is not cosmetic: ArgoCD renders Kustomize **natively**,
with no envsubst plugin, so any `${VAR}` left in the rendered output reaches the
apiserver literally. Every placeholder in `base/` must be overridden by a patch
in `overlays/prod/`.

The prod overlay JSON-patches the NetworkPolicy at `/spec/egress/2/…`. The
egress list order is: `0` DNS, `1` apiserver ClusterIP, **`2` apiserver mgmt
CIDR**, `3` Authentik, `4` public HTTPS. Inserting a rule above index 2 silently
rewrites the wrong rule's CIDR.
