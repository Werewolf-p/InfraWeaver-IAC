# n8n Workflow Blueprints — Developer Feedback → Fix Flow

This directory holds **version-controlled n8n workflow definitions** for the InfraWeaver
platform. n8n itself is **already deployed** (do not redeploy):

- Public: `https://n8n.${BASE_DOMAIN}`
- In-cluster: `http://n8n-api.n8n-prod.svc.cluster.local:8080`
- Namespace: `n8n-prod`

## Files

| File | Purpose |
| --- | --- |
| `dev-feedback-fix-flow.json` | Receives **approved** in-console developer feedback, requires a human approval gate, dispatches a coding agent to implement the fix, tests in the live environment, then pushes to the correct remote. |

## The end-to-end flow

1. **Capture** — A developer clicks the bottom-right *report* button in the console
   (`src/components/feedback/report-button.tsx`) and files a bug / feature-request / note.
   It is stored (auth-gated) via `POST /api/feedback` into the `infraweaver-feedback`
   ConfigMap (namespace `infraweaver-console`), with `status: "new"`.
2. **Review gate (human-in-the-loop #1)** — An admin opens the **Developer Feedback**
   review page (`/feedback`) and explicitly **approves** an entry
   (`PATCH /api/feedback/:id` → `status: "approved"`). This action is **admin-gated**
   (`cluster:admin` / `rbac:admin`). Nothing is auto-executed.
3. **Dispatch** — Only once approved, the console (server-side) calls this workflow's
   authenticated webhook with the approved entry.
4. **Approval gate (human-in-the-loop #2)** — The workflow **pauses** at the
   *Human Approval Gate* node. A human must confirm before any code is generated.
5. **Fix** — `Dispatch Coding Agent` (HTTP Request placeholder) hands the task to
   Copilot CLI / Claude Code.
6. **Test & verify** — `Test in Live Environment` + `Verify Fix Result` run smoke tests;
   failures route to `Rollback / Notify Failure` and never push.
7. **Push (policy routing)** — `Route: Core vs Config` splits by change class.

## Import into n8n

Because the UI import isn't available from this environment, the workflow is stored here
as JSON so it can be imported later:

- **Via UI:** n8n → *Workflows* → *Import from File* → select `dev-feedback-fix-flow.json`.
- **Via API:**
  ```bash
  curl -X POST https://n8n.${BASE_DOMAIN}/api/v1/workflows \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" \
    --data @dev-feedback-fix-flow.json
  ```

After import, create the credentials/env referenced by the placeholder nodes (see below)
and **activate** the workflow.

## Security model

- **Authenticated webhook** — The trigger uses **header auth** (`X-Feedback-Token`,
  credential `feedback-webhook-token`). Unauthenticated calls are rejected. The token is
  an n8n credential, **never** committed here.
- **Reviewable before run** — Entries are captured and must be **explicitly approved by an
  admin** in the console before the webhook is ever called. The webhook also re-validates
  `status == "approved"` (defense in depth).
- **Cannot run without the human approval gate** — Even after an authenticated, approved
  call, the workflow blocks at the *Human Approval Gate* node. No fix is generated or
  pushed until a human confirms.
- **No embedded secrets** — Every token (`GITHUB_TOKEN`, `ONEDEV_TOKEN`,
  `CODING_AGENT_DISPATCH_URL`, the webhook token) is a placeholder resolved from n8n
  env/credentials at runtime.
- **No direct-to-main pushes** — Changes land on a feature branch
  (`n8n/feedback-fix-<id>`) for human PR/MR review.

## Git push policy — GitHub vs OneDev

The `Route: Core vs Config` switch enforces:

| Change class | Remote | Node |
| --- | --- | --- |
| **core / functionality** (application code, features, logic) | **GitHub** only | `Push to GitHub (core)` |
| **config / cluster-state** (manifests, ConfigMaps, infra/cluster config) | **OneDev** only | `Push to OneDev (config)` |

The coding agent must classify its change (`changeClass`) so the switch routes correctly.
Core/functionality changes are pushed to the GitHub remote; config/cluster-state changes
are pushed to the OneDev remote and must **never** be sent to GitHub.

## Required n8n credentials / env (placeholders)

| Name | Used by | Notes |
| --- | --- | --- |
| `feedback-webhook-token` (header auth) | Webhook trigger | Shared secret with the console. |
| `CODING_AGENT_DISPATCH_URL` (env) + header-auth cred | Dispatch Coding Agent | Copilot CLI / Claude Code endpoint. |
| `GITHUB_TOKEN`, `GITHUB_ORG`, `GITHUB_REPO` (env) | Push to GitHub | PAT with repo scope. |
| `ONEDEV_USER`, `ONEDEV_TOKEN`, `ONEDEV_PROJECT` (env) | Push to OneDev | OneDev access token. |

Store all of these as n8n credentials / sealed-secrets — do not commit real values.
