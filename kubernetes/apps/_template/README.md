# _template — App Scaffold Template

This directory is a **reference pointer only**. The actual template files live in `docs/templates/app/`.

**Do not create K8s YAML files directly in this directory** — they would be deployed to the cluster.

## Using the Template

```bash
# From the repo root:
bash scripts/new-app.sh <app-name>
```

This copies `docs/templates/app/manifests/` into `kubernetes/apps/<app-name>/manifests/` with `APP_NAME` replaced throughout.

See `docs/templates/app/README.md` for full documentation.
