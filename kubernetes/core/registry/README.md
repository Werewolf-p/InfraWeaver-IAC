# Self-hosted registry (Zot) + in-cluster BuildKit

Zot OCI registry at **`registry.int.${BASE_DOMAIN}`** is the "image gallery" for the
feedback pipeline. Preview images (one per approved change) and the released
console image are built by the in-cluster BuildKit (`kubernetes/core/buildkit`)
and pushed here — removing GitHub Actions minutes and ghcr pull rate limits.

## Access model
- The registry host carries **no Authentik forward-auth** (docker/buildkit/
  containerd clients can't complete SSO). Zot's own **htpasswd** is the gate.
- DNS is **DNS-only (not Cloudflare-proxied)** — Cloudflare mangles the OCI push
  protocol (415 / connection-reset). Traefik serves the valid `*.int` wildcard cert.
- In-cluster pushers reach Traefik via its **internal MetalLB IP `${METALLB_TRAEFIK_VIP}`**
  (buildkitd `hostAliases`) to avoid the public-IP hairpin that resets uploads.
- Images **must be pushed with OCI media types** (`oci-mediatypes=true`); Zot
  rejects Docker schema2 manifests with `415 Unsupported Media Type`.

## Secrets — provided OUT OF BAND (never in git)
These are created with `kubectl`, not ArgoCD. Recreate if the cluster is rebuilt:

```bash
# 1. Robot credential (push + pull)
ROBOT_USER=infraweaver
ROBOT_PASS=$(openssl rand -hex 24)

# 2. Zot htpasswd Secret (registry ns) — MUST be bcrypt ($2b$), not apr1
HASH=$(python3 -c "import bcrypt,sys;print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt()).decode())" "$ROBOT_PASS")
printf '%s:%s\n' "$ROBOT_USER" "$HASH" > /tmp/zot.htpasswd
kubectl -n registry create secret generic zot-htpasswd --from-file=htpasswd=/tmp/zot.htpasswd
rm -f /tmp/zot.htpasswd

# 3. Pull secret for any namespace that runs registry images (e.g. infraweaver-console)
kubectl -n <ns> create secret docker-registry registry-pull-secret \
  --docker-server=registry.int.${BASE_DOMAIN} \
  --docker-username="$ROBOT_USER" --docker-password="$ROBOT_PASS"
```

The dispatch service on the runner also keeps a copy of the password at
`/home/runner/infraweaver-dispatch/.registry-pass` and a `~/.docker/config.json`
so `buildctl`'s auth provider can push.

> TODO (hardening): migrate `zot-htpasswd` / `registry-pull-secret` to OpenBao +
> ExternalSecrets (ClusterSecretStore `openbao`), and add mTLS to the buildkitd
> NodePort.

## Build/push from the runner
```bash
buildctl --addr tcp://${NODE_1_IP}:31234 build \
  --frontend dockerfile.v0 \
  --local context=<dir> --local dockerfile=<dir> \
  --output type=image,name=registry.int.${BASE_DOMAIN}/<repo>:<tag>,push=true,oci-mediatypes=true
```
