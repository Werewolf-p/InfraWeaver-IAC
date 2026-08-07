# Secure Development Policy

| | |
|---|---|
| **Document ID** | ISMS-POL-004 |
| **Version** | 1.0 |
| **Status** | Active |
| **Effective** | 2026-08-07 |
| **Owner** | Platform Owner |
| **Next review** | On WP1 completion, then 2027-02-07 |
| **Controls** | ISO/IEC 27001:2022 A.8.25, A.8.26, A.8.27, A.8.28, A.8.29, A.8.31, A.8.32, A.8.33, A.5.8, A.8.4 · SOC 2 CC8.1, CC7.1 |

---

## 1. Purpose, and why this document reads differently from the others

Most documents in this pack describe a control that needs building. **This one
describes controls that already exist and were simply never written down.** The
platform's SDLC is materially stronger than its paperwork: seven distinct
automated gates run on every pull request, several of which encode lessons from
specific production incidents.

That is worth stating precisely, because an auditor reading only the gap register
would conclude the change process is weak. It is not weak — it is
**unenforceable at the merge point** (RISK-02), which is a different and narrower
problem.

## 2. Development model

| Property | How it works here |
|---|---|
| Source of truth | Three private GitHub repositories: `InfraWeaver-infra` (GitOps manifests), `InfraWeaver-platform` (application monorepo), `InfraWeaver-base`/`infrastructure` (OpenTofu for Proxmox) |
| Deployment mechanism | **GitOps only.** 61 ArgoCD Applications, 60 with auto-sync. The cluster converges to git; `kubectl apply` is not the change path |
| Environment separation (A.8.31) | Kustomize overlays (`base/` generic, `overlays/prod` with concrete values); `private-test` and `tradesphere` namespaces for non-production workloads; a separate `ontwikkel` Terraform environment. **Not a full parallel environment** — there is one cluster |
| Drift handling | ArgoCD self-heal reconciles the cluster back to git. Live-only fixes are transient by design |
| Public mirror | A sanitised template repository, populated **only** through `scripts/sync-to-public.sh`. A `pre-push` git hook blocks direct pushes to the public mirror (bypass requires `ALLOW_PUBLIC_PUSH=1`), so the sanitiser cannot be skipped by habit |

## 3. Automated gates (A.8.29 — security testing in development)

These are the platform's real SDLC controls. Each is a named job whose failure
is visible on the pull request.

### 3.1 `InfraWeaver-infra` — `validate-iac.yml`

Triggered on pull requests touching `kubernetes/**` and on push to `main`.
Runs `scripts/validate-iac.sh`, a five-stage gate:

| # | Gate | What it prevents |
|---|---|---|
| 1 | **kustomize build** — every `overlays/*/` must render | A manifest that ArgoCD cannot render, i.e. a broken deploy |
| 2 | **kubeconform** — rendered manifests pass Kubernetes schema validation. Dot-directories are excluded (`.impeccable/hook.cache.json` was being parsed as a manifest) | Schema-invalid objects reaching the cluster |
| 3 | **Secret-leak gate (ratcheting)** — no *new* raw `kind: Secret` carrying a real value may be added. Known pre-existing offenders are baselined; **the baseline list is currently empty**, meaning every previously committed raw Secret has been migrated to ExternalSecret/OpenBao | Secrets entering git — and, because of the public mirror, entering a public repository |
| 4 | **Cron-secret seed gate** — every secret key an in-cluster CronJob depends on, when sourced from a catalog app's OpenBao path, must be declared in that app's `catalog.yaml` `secrets.keys` | A fresh install where `seed-catalog-secrets.sh` never seeds a key, ESO cannot sync it, and the CronJob fails **silently, forever**. This gate exists because that happened |
| 5 | **Alert-rule validation** — `promtool` (pinned to 3.13.2, deliberately not `:latest`, so an upstream release cannot turn CI red on a day nothing changed) | Invalid PrometheusRules that silently never fire |

Plus, as separate steps:

- **`validate-netpol-ports.sh`** — catches NetworkPolicy `ports[].port` values
  that match a *Service* port rather than the destination *pod* port. This is
  inert under a non-enforcing CNI and starts dropping traffic the moment Cilium
  enforces. It exists because `allow-traefik-ingress` in the `authentik`
  namespace allowed 80/9300 while `authentik-server` listens on 9000/9443, which
  broke every SSO front-channel login. A genuinely incident-derived control.
- **`validate-eso-refs.sh`** — ExternalSecret reference validation, currently
  `|| true` (informational). **Stated honestly: this gate does not block.**
  Given that 5 of 28 ExternalSecrets are failing (RISK-13), hardening it is
  worth doing.

PyYAML is installed explicitly rather than relied upon from the runner image —
the secret-leak, cron-secret and alert-rule gates all parse manifests with it and
would have degraded silently the day the image dropped it.

### 3.2 `InfraWeaver-infra` — `validate-code.yml`

| Job | Tool | Blocking? |
|---|---|---|
| `shellcheck` | `shellcheck -x --severity=error` over all tracked `*.sh` plus the `pre-push` hook | Yes — errors block, style warnings do not |
| `ruff` | `ruff check scripts` | Yes |
| `terraform` | `tofu fmt -check -recursive` and `tofu validate` | Yes (`continue-on-error: false`, flipped after being proven green) |

### 3.3 `infrastructure` / `InfraWeaver-base` — `security-scan.yml`

| Job | Tool | Behaviour |
|---|---|---|
| Checkov | `bridgecrewio/checkov-action` with `soft_fail: false`, plus an explicit fail-on-HIGH step | Blocking |
| tfsec | fail on CRITICAL or HIGH | Blocking |
| SOPS validation | verifies SOPS configuration and that secret files are actually encrypted | Blocking |
| Policy compliance | aggregate gate — fails the run if any of the above failed | Blocking |

`tofu plan` runs on pull requests so the diff is reviewable before apply.

### 3.4 Local pre-check

`scripts/validate-iac.sh` is designed to run identically on a laptop and in CI —
one definition of "is this safe to merge". `scripts/git-hooks/pre-push`
(installed via `git config core.hooksPath scripts/git-hooks`) guards the
private/public boundary.

## 4. The gap: gates run, but they are not required

**Branch protection cannot be enabled on any of the three repositories.** They
are private on a GitHub free plan; the API returns HTTP 403 "Upgrade to GitHub
Pro or make this repository public".

```bash
gh api repos/example-owner/InfraWeaver-infra/branches/main/protection   # → 403
```

Consequences, stated without softening:

- Every gate in §3 **runs** on a pull request but none is **required** to merge.
- Nothing technically prevents a direct push to `main`.
- `validate-iac.yml` even contains the comment *"branch protection should require
  this check to pass"* — the design intent is documented and unachievable.
- Worst case: `infrastructure/.github/workflows/tofu.yml` triggers on
  `push: branches: [main, ontwikkel]` and runs `make apply` (line 151). **An
  unreviewed push to `main` is an automatic live infrastructure mutation.**

This is RISK-02 and GAP-C1. **WP1** is remediating it by moving the enforcement
point into the workflow — apply becomes `workflow_dispatch`-only with a typed
environment confirmation and a merged-PR-SHA verification step — plus CODEOWNERS
in all three repositories. CODEOWNERS is advisory on the free plan and that is
acknowledged as residual risk.

## 5. Change management procedure (A.8.32 / CC8.1)

1. **Branch.** Never commit to `main`. Never push to `main` in the
   `infrastructure` repository under any circumstances until WP1 lands.
2. **Change one thing.** Where a change is staged (policy Audit→Enforce, network
   policy per namespace, retention changes), one namespace or one policy per
   commit, so revert is atomic.
3. **Open a pull request.** All gates in §3 must be green. A red gate is a stop,
   not a discussion.
4. **Review.** Self-review against `code-review` standards; automated review
   agents for security-sensitive changes. **There is no independent human
   reviewer** — see `information-security-policy.md` §4.
5. **Merge, then let ArgoCD converge.** Do not `kubectl apply`. Do not
   `kubectl patch` a fix — self-heal will revert it.
6. **Verify.** Run the relevant command from `evidence-index.md`. `Synced` is not
   `Healthy`, and `live` is not `available`.

**High-blast-radius changes** — Kyverno Audit→Enforce, PSA level changes,
NetworkPolicy egress-deny in `monitoring` or `traefik`, OpenBao resource
changes, MFA enforcement, Talos machine-config — additionally require the staging
and rollback notes in the plan's §4 breakage flags. A PSA or Kyverno mistake does
**not** break the running pod; it breaks the *next restart*, at an arbitrary
future time. Always follow such a change with a controlled rollout restart in a
window, so failures surface while attention is on them.

## 6. Secure coding (A.8.28)

Standards are defined in the operator's global engineering rules and applied by
review: immutability over mutation, explicit error handling (never swallow),
input validation at every system boundary, no hardcoded values or credentials,
functions under ~50 lines, files under ~800.

Testing (A.8.29): the application monorepo follows a test-driven workflow with an
80% coverage target and a substantial suite (~9,800 tests at the 0.53.0
connector release). Two hard-won rules are recorded here because they are the
kind of thing that is otherwise relearned:

- **`next build` enforces two rules that neither `tsc` nor `jest` can see** — a
  route module may export only Next's own fields, and a wrapper taking an
  optional context parameter fails the generated route validator. A green test
  suite is not a green build.
- **Test files are never typechecked** in this configuration, and
  `jest.mock(..., {virtual: true})` on a module that actually exists is inert.
  A passing mock-based test can be testing nothing.

## 7. Test data (A.8.33)

No production personal data is copied into test fixtures. Test WordPress sites
(`private-test`, `test.${BASE_DOMAIN}`) use synthetic content. The `ontwikkel`
environment holds no user data.

Placeholder credentials in community-app manifests use literal `change-me`
values, which the secret-leak gate recognises as non-real and permits.

## 8. Outsourced development (A.8.30)

None. All development is performed by the platform owner, assisted by AI coding
agents operating under the operator's direction and permission controls. Agent
output is subject to the same pull-request gates as any other change — the gates
in §3 do not distinguish who authored a diff, which is precisely why they are the
load-bearing control here.

## 9. Vulnerability management (A.8.8)

| Layer | Coverage |
|---|---|
| Infrastructure-as-code | **Covered** — Checkov (fail on HIGH) and tfsec (fail on CRITICAL/HIGH) |
| Kubernetes manifests | **Covered** — kubeconform, Kyverno policies, netpol-port gate |
| Shell and Python | **Covered** — shellcheck, ruff |
| Application dependencies | **Not covered** — no automated dependency audit in CI |
| **Container images** | **Not covered** — no Trivy/Grype scan anywhere. Measured 2026-08-07: 83 distinct images in use across 9 registries, 36 from `docker.io`, none digest-pinned; three `:latest`/untagged references live | 

The image gap is RISK-15, **accepted** with a stated rationale: an unfunded
scanner producing thousands of untriaged CVEs is worse than none, because it
manufactures the appearance of a control. WP5 pins the three `:latest` offenders
and WP4 adds a Kyverno registry allowlist, which addresses provenance without the
triage burden.
