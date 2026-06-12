# Git hooks — "develop in private, publish to public via the sanitizer"

These hooks are version-controlled and activated repo-locally with:

```bash
git config core.hooksPath scripts/git-hooks
```

(The runner where dispatch operates already has this set. Anyone cloning the
repo runs the one line above once to opt in.)

## `pre-push`

Enforces the private/public split (`docs/PRIVATE-PUBLIC-GITOPS-AND-DR.md`):

- **PRIVATE `InfraWeaver-infra`** is the full source of truth *and* the ArgoCD
  GitOps source. `terraform/`, `ansible/`, `envs/`, `params/`, and `kubernetes/**`
  config (placeholders intact) all belong here. **Push freely** — developing and
  committing config to the private repo is the intended workflow.
- **PUBLIC `InfraWeaver-template`** is the sanitized, forkable mirror. It receives
  content **only** through `scripts/sync-to-public.sh`, which exports the tracked
  tree with `git archive`, strips IaC + params + prod overlays, and runs a
  deny-scan before pushing.

The hook therefore **blocks a direct `git push` to the public mirror** (that path
would bypass the sanitizer and could leak IaC/params/config). Pushes to the
private infra repo — and any other remote — are unrestricted.

> Previous policy (blocking all `kubernetes/**` config from reaching GitHub)
> assumed OneDev was the GitOps source. OneDev is retired and the private infra
> repo is now the source ArgoCD watches, so that block is obsolete.

### Bypass

```bash
# e.g. seeding a brand-new empty public repo by hand
ALLOW_PUBLIC_PUSH=1 git push <public-remote> <branch>
```
