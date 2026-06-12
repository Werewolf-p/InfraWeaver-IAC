#!/usr/bin/env bash
# =============================================================================
# deploy-n8n.sh — Deploy n8n automation platform with Authentik SSO
#
# On the platform, the n8n workloads (PostgreSQL, n8n, services, forward-auth
# middleware, IngressRoutes) are managed declaratively by ArgoCD (app
# "platform-n8n"). This script therefore focuses on the post-deploy bootstrap
# that ArgoCD cannot do via plain manifests:
#   - Random PostgreSQL credential secret (cannot be committed to git)
#   - Owner account creation (platform owner; password persisted in a secret)
#   - Authentik SSO is wired declaratively (middleware + blueprint + outpost);
#     this script only validates the n8n side is reachable behind it
#   - Feedback/automation workflows (inbox, approval, DNS) on example.com
# It falls back to a fully imperative deploy when ArgoCD is not present (local).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

# Source environment variables (Cloudflare token, etc.)
[[ -f /opt/infraweaver/.env ]] && source /opt/infraweaver/.env

KB_FILE="${KUBECONFIG:-${HOME}/.kube/config-platform-${ENV_NAME:-productie}}"
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
ADMIN_EMAIL="${ADMIN_EMAIL:-noreply@example.com}"
N8N_NAMESPACE="n8n-prod"
N8N_HOST="n8n.int.${BASE_DOMAIN}"
N8N_DB_PASSWORD=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)

log "Deploying n8n to namespace $N8N_NAMESPACE..."

# ── Create namespace ─────────────────────────────────────────────────────────
kubectl --kubeconfig "$KB_FILE" create namespace "$N8N_NAMESPACE" --dry-run=client -o yaml \
  | kubectl --kubeconfig "$KB_FILE" apply -f -

# ── Copy wildcard TLS secret from traefik namespace ──────────────────────────
if ! kubectl --kubeconfig "$KB_FILE" get secret platform-wildcard-tls -n "$N8N_NAMESPACE" &>/dev/null; then
  if kubectl --kubeconfig "$KB_FILE" get secret platform-wildcard-tls -n traefik &>/dev/null; then
    kubectl --kubeconfig "$KB_FILE" get secret platform-wildcard-tls -n traefik -o json \
      | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' \
      | jq ".metadata.namespace=\"$N8N_NAMESPACE\"" \
      | kubectl --kubeconfig "$KB_FILE" apply -n "$N8N_NAMESPACE" -f -
    log "  Copied platform-wildcard-tls to $N8N_NAMESPACE"
  else
    warn "  platform-wildcard-tls not found in traefik namespace (TLS may fail)"
  fi
else
  log "  platform-wildcard-tls already exists in $N8N_NAMESPACE"
fi

# ── Create PostgreSQL credentials secret ─────────────────────────────────────
if ! kubectl --kubeconfig "$KB_FILE" get secret postgresql-n8n-credentials -n "$N8N_NAMESPACE" &>/dev/null; then
  kubectl --kubeconfig "$KB_FILE" create secret generic postgresql-n8n-credentials \
    -n "$N8N_NAMESPACE" \
    --from-literal=database=n8n \
    --from-literal=username=n8n \
    --from-literal=password="$N8N_DB_PASSWORD"
  log "  Created postgresql-n8n-credentials secret"
else
  N8N_DB_PASSWORD=$(kubectl --kubeconfig "$KB_FILE" get secret postgresql-n8n-credentials \
    -n "$N8N_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
  log "  postgresql-n8n-credentials secret already exists"
fi

# ── Workload ownership: ArgoCD vs imperative ────────────────────────────────
# PostgreSQL, n8n, the forward-auth middleware and the IngressRoutes are all
# managed declaratively by ArgoCD (kubernetes/platform/n8n/manifests, app
# "platform-n8n") on the platform. Re-applying them here previously pinned the
# broken n8nio/n8n:1.61.0 image and fought ArgoCD selfHeal, so n8n CrashLooped
# and this script bailed *before* ever creating the owner account or workflows
# — which is exactly why owner/Authentik/feedback "wasn't working".
# When ArgoCD owns n8n we skip the imperative deploy and just wait for it to be
# Ready; otherwise (a standalone/local run with no ArgoCD) we deploy directly.
if kubectl --kubeconfig "$KB_FILE" get application platform-n8n -n argocd &>/dev/null; then
  log "  n8n is ArgoCD-managed (app platform-n8n) — skipping imperative resource deploy"
  log "  Waiting for ArgoCD-managed PostgreSQL to be ready..."
  kubectl --kubeconfig "$KB_FILE" wait --for=condition=ready pod -l app=postgresql-n8n \
    -n "$N8N_NAMESPACE" --timeout=180s 2>/dev/null || warn "  PostgreSQL not ready yet"
else
# ── Ensure PostgreSQL PVC (idempotent; tolerate pre-existing immutable PVC) ───
if ! kubectl --kubeconfig "$KB_FILE" get pvc postgresql-n8n-data -n "$N8N_NAMESPACE" &>/dev/null; then
  kubectl --kubeconfig "$KB_FILE" apply -f - <<EOF || warn "  PVC apply failed (non-fatal)"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-n8n-data
  namespace: $N8N_NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path-retain
  resources:
    requests:
      storage: 5Gi
EOF
else
  log "  postgresql-n8n-data PVC already exists"
fi

# ── Deploy PostgreSQL ────────────────────────────────────────────────────────
kubectl --kubeconfig "$KB_FILE" apply -f - <<EOF && true || warn "  resource apply conflict (managed by ArgoCD, non-fatal)"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql-n8n
  namespace: $N8N_NAMESPACE
  labels:
    app: postgresql-n8n
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgresql-n8n
  template:
    metadata:
      labels:
        app: postgresql-n8n
    spec:
      containers:
      - name: postgresql
        image: postgres:15-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: n8n
        - name: POSTGRES_USER
          value: n8n
        - name: POSTGRES_PASSWORD
          value: "$N8N_DB_PASSWORD"
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        - name: POSTGRES_HOST_AUTH_METHOD
          value: md5
        - name: POSTGRES_INITDB_ARGS
          value: "--auth-host=md5 --auth-local=md5"
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: 128Mi
            cpu: 100m
          limits:
            memory: 512Mi
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: postgresql-n8n-data
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql-n8n
  namespace: $N8N_NAMESPACE
spec:
  clusterIP: None
  selector:
    app: postgresql-n8n
  ports:
  - port: 5432
    targetPort: 5432
EOF
log "  PostgreSQL deployed"

# Wait for PostgreSQL to be ready
for i in $(seq 1 30); do
  if kubectl --kubeconfig "$KB_FILE" get pod -n "$N8N_NAMESPACE" -l app=postgresql-n8n \
    --no-headers 2>/dev/null | grep -q "Running"; then
    break
  fi
  sleep 5
done
kubectl --kubeconfig "$KB_FILE" wait --for=condition=ready pod -l app=postgresql-n8n \
  -n "$N8N_NAMESPACE" --timeout=120s 2>/dev/null || warn "PostgreSQL not ready yet"

# ── Deploy n8n ───────────────────────────────────────────────────────────────
kubectl --kubeconfig "$KB_FILE" apply -f - <<EOF && true || warn "  resource apply conflict (managed by ArgoCD, non-fatal)"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
  namespace: $N8N_NAMESPACE
  labels:
    app: n8n
spec:
  replicas: 1
  selector:
    matchLabels:
      app: n8n
  template:
    metadata:
      labels:
        app: n8n
    spec:
      containers:
      - name: n8n
        image: n8nio/n8n:1.123.50
        ports:
        - containerPort: 5678
        env:
        - name: N8N_HOST
          value: "$N8N_HOST"
        - name: N8N_PROTOCOL
          value: https
        - name: N8N_PORT
          value: "5678"
        - name: WEBHOOK_URL
          value: "https://$N8N_HOST"
        - name: N8N_EDITOR_BASE_URL
          value: "https://$N8N_HOST"
        - name: N8N_AUTH_EXCLUDE_ENDPOINTS
          value: "rest/oauth2-credential/callback"
        - name: N8N_USER_MANAGEMENT_DISABLED
          value: "false"
        - name: NODE_ENV
          value: production
        - name: DB_TYPE
          value: postgresdb
        - name: DB_POSTGRESDB_HOST
          value: postgresql-n8n
        - name: DB_POSTGRESDB_PORT
          value: "5432"
        - name: DB_POSTGRESDB_DATABASE
          value: n8n
        - name: DB_POSTGRESDB_USER
          value: n8n
        - name: DB_POSTGRESDB_PASSWORD
          value: "$N8N_DB_PASSWORD"
        - name: N8N_EXECUTIONS_MODE
          value: regular
        - name: LOG_LEVEL
          value: info
        resources:
          requests:
            memory: 256Mi
            cpu: 200m
          limits:
            memory: 1Gi
        livenessProbe:
          httpGet:
            path: /healthz
            port: 5678
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /healthz
            port: 5678
          initialDelaySeconds: 10
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: n8n-api
  namespace: $N8N_NAMESPACE
spec:
  selector:
    app: n8n
  ports:
  - port: 8080
    targetPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: n8n-http
  namespace: $N8N_NAMESPACE
spec:
  type: LoadBalancer
  selector:
    app: n8n
  ports:
  - port: 8080
    targetPort: 5678
EOF
log "  n8n deployed"

# ── Create Traefik forward-auth middleware ───────────────────────────────────
kubectl --kubeconfig "$KB_FILE" apply -f - <<EOF && true || warn "  resource apply conflict (managed by ArgoCD, non-fatal)"
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: n8n-forward-auth
  namespace: $N8N_NAMESPACE
spec:
  forwardAuth:
    address: http://authentik-server.authentik.svc.cluster.local:80/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
      - authorization
EOF
log "  Forward-auth middleware created"

# ── Create IngressRoutes ─────────────────────────────────────────────────────
kubectl --kubeconfig "$KB_FILE" apply -f - <<EOF && true || warn "  resource apply conflict (managed by ArgoCD, non-fatal)"
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: n8n-webhooks
  namespace: $N8N_NAMESPACE
spec:
  entryPoints: [websecure]
  routes:
  - match: Host(\`$N8N_HOST\`) && (PathPrefix(\`/webhook/\`) || PathPrefix(\`/webhook-test/\`) || Path(\`/healthz\`) || PathPrefix(\`/rest/oauth2-credential/callback\`))
    kind: Rule
    priority: 20
    services:
    - name: n8n-api
      port: 8080
  tls:
    secretName: platform-wildcard-tls
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: n8n-main
  namespace: $N8N_NAMESPACE
spec:
  entryPoints: [websecure]
  routes:
  - match: Host(\`$N8N_HOST\`)
    kind: Rule
    priority: 10
    services:
    - name: n8n-api
      port: 8080
    middlewares:
    - name: n8n-forward-auth
      namespace: $N8N_NAMESPACE
  tls:
    secretName: platform-wildcard-tls
EOF
log "  IngressRoutes created"

fi

# ── Wait for n8n to be ready (shared: ArgoCD-managed or imperative) ──────────
log "  Waiting for n8n to be ready..."
kubectl --kubeconfig "$KB_FILE" wait --for=condition=ready pod -l app=n8n \
  -n "$N8N_NAMESPACE" --timeout=300s 2>/dev/null || {
    warn "n8n not ready after 5 minutes — skipping owner/workflow bootstrap"
    return 0 2>/dev/null || exit 0
  }
sleep 10

# ── Get n8n service endpoint for API calls ───────────────────────────────────
N8N_LB_IP=$(kubectl --kubeconfig "$KB_FILE" get svc n8n-http -n "$N8N_NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [[ -z "$N8N_LB_IP" ]]; then
  N8N_NODE_IP=$(kubectl --kubeconfig "$KB_FILE" get pod -n "$N8N_NAMESPACE" -l app=n8n \
    -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null || echo "")
  N8N_NODE_PORT=$(kubectl --kubeconfig "$KB_FILE" get svc n8n-http -n "$N8N_NAMESPACE" \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
  N8N_URL="http://${N8N_NODE_IP}:${N8N_NODE_PORT}"
else
  N8N_URL="http://${N8N_LB_IP}:8080"
fi
log "  n8n API endpoint: $N8N_URL"

# ── Create owner account (n8n internal /rest API) ────────────────────────────
# Owner password is generated once and persisted in a k8s secret — never committed
# to git, and kept consistent across redeploys so this script can log back in to
# manage workflows. The n8n UI is fronted by Authentik SSO (forward-auth
# middleware), so this native credential is only for API bootstrap.
if kubectl --kubeconfig "$KB_FILE" get secret n8n-owner-credentials -n "$N8N_NAMESPACE" &>/dev/null; then
  N8N_OWNER_PASSWORD=$(kubectl --kubeconfig "$KB_FILE" get secret n8n-owner-credentials \
    -n "$N8N_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
  log "  Reusing existing n8n owner credentials"
else
  # n8n password policy: ≥8 chars, ≥1 number, ≥1 uppercase — suffix guarantees all three.
  N8N_OWNER_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)Aa1!"
  kubectl --kubeconfig "$KB_FILE" create secret generic n8n-owner-credentials \
    -n "$N8N_NAMESPACE" \
    --from-literal=email="$ADMIN_EMAIL" \
    --from-literal=password="$N8N_OWNER_PASSWORD" 2>/dev/null \
    && log "  Stored n8n owner credentials in secret n8n-owner-credentials" \
    || warn "  Could not create n8n-owner-credentials secret"
fi
N8N_BID="deploy-script"
OWNER_RESP=$(curl -s --max-time 30 "$N8N_URL/rest/owner/setup" \
  -H "Content-Type: application/json" -H "browser-id: $N8N_BID" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"firstName\":\"Admin\",\"lastName\":\"Owner\",\"password\":\"$N8N_OWNER_PASSWORD\"}" 2>/dev/null || echo "")
if echo "$OWNER_RESP" | grep -q '"id"'; then
  log "  ✅ n8n owner account created"
else
  log "  n8n owner account already exists (or already set up)"
fi

# ── Login and capture session cookie (n8n binds the cookie JWT to browser-id) ─
# n8n's /rest/login renamed the identity field from "email" to "emailOrLdapLoginId"
# (n8n ≥ 1.x). Sending the legacy "email" field alone yields HTTP 400 and a *silent*
# skip of all workflow creation — which is why the feedback/automation workflows
# never appeared on rlservers. We send both keys so login works across n8n versions.
curl -s --max-time 15 -D /tmp/n8n_deploy_hdrs.txt -o /dev/null "$N8N_URL/rest/login" \
  -H "Content-Type: application/json" -H "browser-id: $N8N_BID" \
  -d "{\"emailOrLdapLoginId\":\"$ADMIN_EMAIL\",\"email\":\"$ADMIN_EMAIL\",\"password\":\"$N8N_OWNER_PASSWORD\"}" 2>/dev/null || true
N8N_COOKIE=$(grep -i 'set-cookie' /tmp/n8n_deploy_hdrs.txt 2>/dev/null | grep -o 'n8n-auth=[^;]*' | head -1)
if [[ -z "$N8N_COOKIE" ]]; then
  warn "  n8n login failed — skipping workflow creation."
  warn "  (Owner may have been created out-of-band; ensure secret n8n-owner-credentials"
  warn "   in ns $N8N_NAMESPACE holds the native password, then re-run this script.)"
  exit 0
fi
log "  ✅ Logged in to n8n"
AUTH=(-b "$N8N_COOKIE" -H "browser-id: $N8N_BID")

# ── Determine GitHub repo for issues ─────────────────────────────────────────
# Bug/feature/note issues are ALWAYS sent to the platform repo on example.com
GH_ISSUES_REPO="${GH_ISSUES_REPO:-${GITHUB_REPO:-your-org/your-repo}}"
GH_OWNER="${GH_ISSUES_REPO%%/*}"
GH_REPO_NAME="${GH_ISSUES_REPO##*/}"
# Webhook domain (legacy n8n automation); defaults to this deployment's domain.
WEBHOOK_DOMAIN="${WEBHOOK_DOMAIN:-$BASE_DOMAIN}"

# ── Create GitHub API credential ─────────────────────────────────────────────
GH_TOKEN=$(gh auth token 2>/dev/null || echo "")
GH_CRED_ID=""
if [[ -n "$GH_TOKEN" ]]; then
  CRED_RESP=$(curl -s --max-time 15 "${AUTH[@]}" "$N8N_URL/rest/credentials" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"GitHub Token\",\"type\":\"githubApi\",\"data\":{\"server\":\"https://api.github.com\",\"user\":\"$GH_OWNER\",\"accessToken\":\"$GH_TOKEN\"}}" 2>/dev/null || echo "")
  GH_CRED_ID=$(echo "$CRED_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null || echo "")
  if [[ -n "$GH_CRED_ID" ]]; then
    log "  ✅ GitHub credential created (id=$GH_CRED_ID)"
  else
    GH_CRED_ID=$(curl -s --max-time 15 "${AUTH[@]}" "$N8N_URL/rest/credentials" 2>/dev/null \
      | python3 -c "import json,sys; creds=json.load(sys.stdin).get('data',[]); print(next((c['id'] for c in creds if c.get('name')=='GitHub Token'),''))" 2>/dev/null || echo "")
    [[ -n "$GH_CRED_ID" ]] && log "  GitHub credential already exists (id=$GH_CRED_ID)"
  fi
fi

# ── Helper: create a workflow (inactive) then activate it via PATCH ───────────
# n8n /rest/workflows requires the 'active' field present and rejects creating an
# already-active workflow, so we create inactive then PATCH active=true.
create_workflow() {
  local payload="$1"; local label="$2"
  local resp wid
  resp=$(curl -s --max-time 15 "${AUTH[@]}" "$N8N_URL/rest/workflows" \
    -H "Content-Type: application/json" -d "$payload" 2>/dev/null || echo "")
  wid=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null || echo "")
  if [[ -n "$wid" ]]; then
    curl -s --max-time 15 "${AUTH[@]}" -X PATCH "$N8N_URL/rest/workflows/$wid" \
      -H "Content-Type: application/json" -d '{"active":true}' >/dev/null 2>&1 || true
    log "  ✅ $label workflow created + activated (id=$wid)"
  else
    warn "  $label workflow creation failed: $(echo "$resp" | head -c 200)"
  fi
}

# ── Create automation workflows ──────────────────────────────────────────────
# Only set up bug/feature/notes automation on example.com deployments
if [[ -n "$GH_TOKEN" && "${ENABLE_N8N_AUTOMATION:-false}" == "true" ]]; then
  # Workflow 1: Automation Inbox (receives bugs/features/notes, creates GitHub issues)
  # Uses Code node with this.helpers.httpRequest() (proven working approach)
  INBOX_CODE="const input = \$input.first().json.body;\\nconst ghToken = '${GH_TOKEN}';\\nconst type = input.type || 'note';\\nconst title = type + ': ' + (input.title || 'Untitled');\\nconst body = '**Type:** ' + type + '\\\\n**Priority:** ' + (input.priority || 'medium') + '\\\\n\\\\n' + (input.body || input.description || '');\\nconst data = await this.helpers.httpRequest({\\n  method: 'POST',\\n  url: 'https://api.github.com/repos/${GH_OWNER}/${GH_REPO_NAME}/issues',\\n  headers: { 'Authorization': 'token ' + ghToken, 'User-Agent': 'n8n-automation', 'Accept': 'application/vnd.github.v3+json' },\\n  body: { title: title, body: body, labels: [type] },\\n  json: true\\n});\\nreturn [{json: {status: 'ok', issue: data.number, url: data.html_url}}];"

  create_workflow "{
      \"name\": \"Automation Inbox\",
      \"active\": false,
      \"settings\": {\"saveDataErrorExecution\":\"all\",\"saveDataSuccessExecution\":\"all\",\"saveExecutionProgress\":true,\"executionTimeout\":30},
      \"nodes\": [
        {\"parameters\":{\"httpMethod\":\"POST\",\"path\":\"inbox\",\"responseMode\":\"responseNode\",\"options\":{}},\"id\":\"wh1\",\"name\":\"Webhook\",\"type\":\"n8n-nodes-base.webhook\",\"typeVersion\":2,\"position\":[250,300],\"webhookId\":\"inbox\"},
        {\"parameters\":{\"jsCode\":\"${INBOX_CODE}\"},\"id\":\"code1\",\"name\":\"Create Issue\",\"type\":\"n8n-nodes-base.code\",\"typeVersion\":2,\"position\":[470,300]},
        {\"parameters\":{\"respondWith\":\"json\",\"responseBody\":\"={{ \$json }}\"},\"id\":\"resp1\",\"name\":\"Respond\",\"type\":\"n8n-nodes-base.respondToWebhook\",\"typeVersion\":1,\"position\":[690,300]}
      ],
      \"connections\": {
        \"Webhook\": {\"main\":[[{\"node\":\"Create Issue\",\"type\":\"main\",\"index\":0}]]},
        \"Create Issue\": {\"main\":[[{\"node\":\"Respond\",\"type\":\"main\",\"index\":0}]]}
      }
    }" "Inbox"

  # Workflow 2: Approval and Deploy (labels issues as approved)
  APPROVE_CODE="const input = \$input.first().json.body;\\nconst ghToken = '${GH_TOKEN}';\\nconst issueNum = input.issue_number || input.issue;\\nif (!issueNum) { throw new Error('Missing issue or issue_number field'); }\\nconst action = input.action || 'approve';\\nconst labels = action === 'reject' ? ['rejected'] : ['approved', 'automation'];\\nconst data = await this.helpers.httpRequest({\\n  method: 'PATCH',\\n  url: 'https://api.github.com/repos/${GH_OWNER}/${GH_REPO_NAME}/issues/' + issueNum,\\n  headers: { 'Authorization': 'token ' + ghToken, 'User-Agent': 'n8n-automation', 'Accept': 'application/vnd.github.v3+json' },\\n  body: { labels: labels },\\n  json: true\\n});\\nreturn [{json: {status: action, issue: data.number, labels: labels}}];"

  create_workflow "{
      \"name\": \"Approval and Deploy\",
      \"active\": false,
      \"settings\": {\"saveDataErrorExecution\":\"all\",\"saveDataSuccessExecution\":\"all\",\"saveExecutionProgress\":true,\"executionTimeout\":30},
      \"nodes\": [
        {\"parameters\":{\"httpMethod\":\"POST\",\"path\":\"approve\",\"responseMode\":\"responseNode\",\"options\":{}},\"id\":\"wh2\",\"name\":\"Webhook\",\"type\":\"n8n-nodes-base.webhook\",\"typeVersion\":2,\"position\":[250,300],\"webhookId\":\"approve\"},
        {\"parameters\":{\"jsCode\":\"${APPROVE_CODE}\"},\"id\":\"code2\",\"name\":\"Approve\",\"type\":\"n8n-nodes-base.code\",\"typeVersion\":2,\"position\":[470,300]},
        {\"parameters\":{\"respondWith\":\"json\",\"responseBody\":\"={{ \$json }}\"},\"id\":\"resp2\",\"name\":\"Respond\",\"type\":\"n8n-nodes-base.respondToWebhook\",\"typeVersion\":1,\"position\":[690,300]}
      ],
      \"connections\": {
        \"Webhook\": {\"main\":[[{\"node\":\"Approve\",\"type\":\"main\",\"index\":0}]]},
        \"Approve\": {\"main\":[[{\"node\":\"Respond\",\"type\":\"main\",\"index\":0}]]}
      }
    }" "Approval"

  # Workflow 3: DNS Manager (CRUD for Cloudflare DNS records via webhook)
  CF_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
  CF_ZONE="${CLOUDFLARE_ZONE_ID:-5a77d9adc2dfba4eec70049afd93ab54}"
  if [[ -n "$CF_TOKEN" ]]; then
    # Write DNS Manager code to temp file (avoids shell escaping issues)
    cat > /tmp/dns_manager_deploy.js << 'DNS_JS_EOF'
const body = $input.first().json.body || $input.first().json;
const action = body.action || 'list';
const cfToken = '__CF_TOKEN__';
const cfZone = '__CF_ZONE__';
const baseUrl = `https://api.cloudflare.com/client/v4/zones/${cfZone}/dns_records`;
const headers = { 'Authorization': `Bearer ${cfToken}`, 'Content-Type': 'application/json' };
async function cfReq(method, url, data) { const opts = { method, url, headers, json: true }; if (data) opts.body = data; return await this.helpers.httpRequest(opts); }
const dohResolvers = [{ name: 'Cloudflare', url: 'https://cloudflare-dns.com/dns-query' }, { name: 'Google', url: 'https://dns.google/resolve' }];
async function dohQuery(domain, resolver) { try { const resp = await this.helpers.httpRequest({ method: 'GET', url: `${resolver.url}?name=${domain}&type=A`, headers: { 'Accept': 'application/dns-json' }, json: true, timeout: 8000 }); return { resolver: resolver.name, ok: resp.Status === 0, answers: (resp.Answer||[]).map(a => a.data) }; } catch(e) { return { resolver: resolver.name, ok: false, error: e.message }; } }
try {
if (action === 'list') { let url = `${baseUrl}?per_page=100`; if (body.filter) url += `&name=${body.filter}`; if (body.type) url += `&type=${body.type}`; const resp = await cfReq.call(this, 'GET', url); const records = (resp.result||[]).filter(r => !r.name.startsWith('edns-')).map(r => ({ id: r.id, name: r.name, type: r.type, content: r.content, proxied: r.proxied, ttl: r.ttl, tier: r.name.includes('.int.') ? 'private' : (r.proxied ? 'public-cdn' : 'public-direct'), managed_by: (r.comment||'').includes('external-dns') ? 'external-dns' : 'manual' })); return [{json: {status:'ok', count:records.length, records}}]; }
if (action === 'create') { const {name, type='A', content, proxied, ttl=1, comment=''} = body; if (!name || !content) throw new Error('Required: name, content'); const isInt = name.includes('.int.'); const shouldProxy = proxied !== undefined ? proxied : !isInt; const resp = await cfReq.call(this, 'POST', baseUrl, { type, name, content, proxied: shouldProxy, ttl: shouldProxy ? 1 : (ttl||300), comment: comment || `DNS Manager | ${new Date().toISOString()}` }); if (!resp.success) throw new Error(JSON.stringify(resp.errors)); return [{json: {status:'ok', action:'created', record: {id:resp.result.id, name:resp.result.name, content:resp.result.content, proxied:resp.result.proxied}}}]; }
if (action === 'update') { const {id, name, type, content, proxied, ttl} = body; if (!id && !name) throw new Error('Required: id or name'); let recordId = id; if (!recordId) { const s = await cfReq.call(this, 'GET', `${baseUrl}?name=${name}`); if (!s.result || !s.result.length) throw new Error(`Not found: ${name}`); recordId = s.result[0].id; } const patch = {}; if (content) patch.content = content; if (proxied !== undefined) patch.proxied = proxied; if (ttl) patch.ttl = ttl; if (type) patch.type = type; const resp = await cfReq.call(this, 'PATCH', `${baseUrl}/${recordId}`, patch); if (!resp.success) throw new Error(JSON.stringify(resp.errors)); return [{json: {status:'ok', action:'updated', record: {id:resp.result.id, name:resp.result.name, content:resp.result.content, proxied:resp.result.proxied}}}]; }
if (action === 'delete') { let recordId = body.id; if (!recordId && body.name) { const s = await cfReq.call(this, 'GET', `${baseUrl}?name=${body.name}`); if (!s.result || !s.result.length) throw new Error(`Not found: ${body.name}`); recordId = s.result[0].id; } if (!recordId) throw new Error('Required: id or name'); const resp = await cfReq.call(this, 'DELETE', `${baseUrl}/${recordId}`); if (!resp.success) throw new Error(JSON.stringify(resp.errors)); return [{json: {status:'ok', action:'deleted', id: recordId}}]; }
if (action === 'health') { const resp = await cfReq.call(this, 'GET', `${baseUrl}?per_page=100&type=A`); const records = (resp.result||[]).filter(r => !r.name.startsWith('edns-') && !r.name.includes('.int.')); const results = []; for (const r of records.slice(0, 20)) { const checks = await Promise.all(dohResolvers.map(res => dohQuery.call(this, r.name, res))); const healthy = checks.every(c => c.ok); results.push({name:r.name, proxied:r.proxied, healthy, checks: checks.map(c=>({resolver:c.resolver, ok:c.ok, ips:c.answers||[], error:c.error}))}); } const unhealthy = results.filter(r => !r.healthy); return [{json: {status:'ok', total:results.length, healthy:results.length-unhealthy.length, unhealthy:unhealthy.length, issues: unhealthy.length>0 ? unhealthy : undefined, all_records: results}}]; }
if (action === 'propagation') { if (!body.domain) throw new Error('Required: domain'); const checks = await Promise.all(dohResolvers.map(r => dohQuery.call(this, body.domain, r))); const okChecks = checks.filter(c => c.ok); return [{json: {status:'ok', domain:body.domain, propagated:okChecks.length===dohResolvers.length, coverage:`${okChecks.length}/${dohResolvers.length}`, resolvers:checks}}]; }
if (action === 'suggest') { const resp = await cfReq.call(this, 'GET', `${baseUrl}?per_page=100&type=A`); const existing = new Set((resp.result||[]).map(r => r.name)); const services = ['grafana','prometheus','longhorn','argocd','openbao','wiki','gitea','vaultwarden','forgejo','it-tools','stirling-pdf','excalidraw','actual']; const suggestions = services.filter(s => !existing.has(`${s}.int.example.com`)).map(s => ({ name:`${s}.int.example.com`, type:'A', content:'10.10.0.200', proxied:false, note:'Covered by wildcard but explicit record improves monitoring visibility' })); return [{json: {status:'ok', suggestions, total:suggestions.length}}]; }
if (action === 'bulk') { const ops = body.operations || []; if (!ops.length) throw new Error('Required: operations array'); const results = []; for (const op of ops) { try { if (op.action === 'create') { const r = await cfReq.call(this, 'POST', baseUrl, {type:op.type||'A', name:op.name, content:op.content, proxied:!!op.proxied, ttl:op.ttl||1, comment:'Bulk DNS Manager'}); results.push({name:op.name, ok:r.success}); } else if (op.action === 'delete') { let rid = op.id; if (!rid && op.name) { const s = await cfReq.call(this,'GET',`${baseUrl}?name=${op.name}`); rid = s.result && s.result[0] ? s.result[0].id : null; } if (rid) { const r = await cfReq.call(this,'DELETE',`${baseUrl}/${rid}`); results.push({name:op.name||op.id, ok:r.success}); } else results.push({name:op.name, ok:false, error:'Not found'}); } } catch(e) { results.push({name:op.name, ok:false, error:e.message}); } } return [{json: {status:'ok', action:'bulk', total:results.length, succeeded:results.filter(r=>r.ok).length, results}}]; }
if (action === 'stats') { const resp = await cfReq.call(this, 'GET', `${baseUrl}?per_page=100`); const records = (resp.result||[]).filter(r => !r.name.startsWith('edns-')); const byType = {}; const byTier = {}; for (const r of records) { byType[r.type] = (byType[r.type]||0) + 1; const tier = r.name.includes('.int.') ? 'private' : (r.proxied ? 'public-cdn' : 'public-direct'); byTier[tier] = (byTier[tier]||0) + 1; } return [{json: {status:'ok', total:records.length, by_type:byType, by_tier:byTier}}]; }
return [{json: {status:'error', message:`Unknown action: ${action}`, available:['list','create','update','delete','health','propagation','suggest','bulk','stats']}}];
} catch(e) { return [{json: {status:'error', message:e.message}}]; }
DNS_JS_EOF
    # Inject tokens into the JS code
    sed -i "s|__CF_TOKEN__|${CF_TOKEN}|" /tmp/dns_manager_deploy.js
    sed -i "s|__CF_ZONE__|${CF_ZONE}|" /tmp/dns_manager_deploy.js

    # Build and deploy workflow using Python (to handle JSON properly)
    python3 -c "
import json, sys
with open('/tmp/dns_manager_deploy.js') as f:
    code = f.read()
wf = {
    'name': 'DNS Manager',
    'active': False,
    'settings': {'saveDataErrorExecution':'all','saveDataSuccessExecution':'none','executionTimeout':120},
    'nodes': [
        {'parameters':{'httpMethod':'POST','path':'dns','responseMode':'responseNode','options':{}},'id':'dns-wh','name':'DNS Webhook','type':'n8n-nodes-base.webhook','typeVersion':2,'position':[250,300],'webhookId':'dns'},
        {'parameters':{'jsCode':code},'id':'dns-code','name':'DNS Operations','type':'n8n-nodes-base.code','typeVersion':2,'position':[470,300]},
        {'parameters':{'respondWith':'json','responseBody':'={{ \$json }}'},'id':'dns-resp','name':'Respond','type':'n8n-nodes-base.respondToWebhook','typeVersion':1,'position':[690,300]}
    ],
    'connections': {'DNS Webhook':{'main':[[{'node':'DNS Operations','type':'main','index':0}]]},'DNS Operations':{'main':[[{'node':'Respond','type':'main','index':0}]]}}
}
with open('/tmp/dns_manager_workflow.json','w') as f:
    json.dump(wf, f)
"
    create_workflow "$(cat /tmp/dns_manager_workflow.json)" "DNS Manager"
    rm -f /tmp/dns_manager_deploy.js /tmp/dns_manager_workflow.json

    # Workflow 4: DNS Health Monitor (checks every 5 min, alerts on failures)
    cat > /tmp/dns_health_deploy.js << 'HEALTH_JS_EOF'
const cfToken = '__CF_TOKEN__';
const cfZone = '__CF_ZONE__';
const baseUrl = `https://api.cloudflare.com/client/v4/zones/${cfZone}/dns_records`;
const headers = { 'Authorization': `Bearer ${cfToken}`, 'Content-Type': 'application/json' };
const dohEndpoints = [{ name: 'Cloudflare', url: 'https://cloudflare-dns.com/dns-query' }, { name: 'Google', url: 'https://dns.google/resolve' }];
async function checkDomain(domain, endpoint) { try { const resp = await this.helpers.httpRequest({ method: 'GET', url: `${endpoint.url}?name=${domain}&type=A`, headers: { 'Accept': 'application/dns-json' }, json: true, timeout: 8000 }); return { resolver: endpoint.name, ok: resp.Status === 0, answers: (resp.Answer||[]).map(a => a.data) }; } catch(e) { return { resolver: endpoint.name, ok: false, error: e.message }; } }
const resp = await this.helpers.httpRequest({ method: 'GET', url: `${baseUrl}?per_page=100&type=A`, headers, json: true });
const records = (resp.result || []).filter(r => !r.name.startsWith('edns-') && !r.name.includes('.int.'));
const issues = [];
for (const r of records) { const checks = await Promise.all(dohEndpoints.map(ep => checkDomain.call(this, r.name, ep))); if (!checks.every(c => c.ok)) { issues.push({ name: r.name, proxied: r.proxied, failed: checks.filter(c => !c.ok).map(c => `${c.resolver}: ${c.error || 'NXDOMAIN'}`) }); } }
if (issues.length > 0) { const desc = issues.map(i => `- ${i.name} (proxied=${i.proxied}) failed: ${i.failed.join(', ')}`).join('\n'); await this.helpers.httpRequest({ method: 'POST', url: 'https://n8n.example.com/webhook/inbox', headers: { 'Content-Type': 'application/json' }, body: { type: 'bug', title: `DNS: ${issues.length} record(s) failing resolution`, description: `DNS Health Monitor alert:\n${desc}`, source: 'dns-health-monitor', priority: 'high' }, json: true }); }
return [{ json: { timestamp: new Date().toISOString(), checked: records.length, healthy: records.length - issues.length, issues: issues.length, details: issues } }];
HEALTH_JS_EOF
    sed -i "s|__CF_TOKEN__|${CF_TOKEN}|" /tmp/dns_health_deploy.js
    sed -i "s|__CF_ZONE__|${CF_ZONE}|" /tmp/dns_health_deploy.js

    python3 -c "
import json
with open('/tmp/dns_health_deploy.js') as f:
    code = f.read()
wf = {
    'name': 'DNS Health Monitor',
    'active': False,
    'settings': {'saveDataErrorExecution':'all','saveDataSuccessExecution':'none','executionTimeout':120},
    'nodes': [
        {'parameters':{'rule':{'interval':[{'field':'minutes','minutesInterval':5}]}},'id':'t1','name':'Every 5 Minutes','type':'n8n-nodes-base.scheduleTrigger','typeVersion':1.2,'position':[250,300]},
        {'parameters':{'jsCode':code},'id':'h1','name':'Check DNS Health','type':'n8n-nodes-base.code','typeVersion':2,'position':[470,300]}
    ],
    'connections': {'Every 5 Minutes':{'main':[[{'node':'Check DNS Health','type':'main','index':0}]]}}
}
with open('/tmp/dns_health_workflow.json','w') as f:
    json.dump(wf, f)
"
    create_workflow "$(cat /tmp/dns_health_workflow.json)" "DNS Health Monitor"
    rm -f /tmp/dns_health_deploy.js /tmp/dns_health_workflow.json
    log "  ✅ DNS workflows deployed (Manager + Health Monitor)"
  else
    log "  ⏭ Skipping DNS workflows (CLOUDFLARE_API_TOKEN not set)"
  fi

  # Ensure required labels exist in the GitHub repo
  for label_name in "feature:a2eeef:Feature request" "bug:d73a4a:Bug report" "note:d876e3:Note/observation" "approved:0e8a16:Approved for implementation" "automation:1d76db:Automated processing"; do
    IFS=: read -r lname lcolor ldesc <<< "$label_name"
    gh label create "$lname" --color "$lcolor" --description "$ldesc" --repo "$GH_ISSUES_REPO" 2>/dev/null || true
  done
  log "  ✅ GitHub labels ensured"
elif [[ -n "$GH_TOKEN" && "${ENABLE_N8N_AUTOMATION:-false}" != "true" ]]; then
  log "  ⏭ Skipping workflow setup (only configured for example.com domain)"
  log "  ℹ Webhooks from this deployment will send to https://n8n.example.com/webhook/inbox"
fi

# ── Verify webhook registration ──────────────────────────────────────────────
sleep 5
HEALTHZ=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$N8N_URL/webhook/test" 2>/dev/null || echo "000")
# webhooks may need a restart to register (n8n quirk when created via API while running)
if [[ "$HEALTHZ" == "000" ]]; then
  log "  Restarting n8n to register webhooks..."
  kubectl --kubeconfig "$KB_FILE" rollout restart deployment/n8n -n "$N8N_NAMESPACE"
  kubectl --kubeconfig "$KB_FILE" rollout status deployment/n8n -n "$N8N_NAMESPACE" --timeout=120s 2>/dev/null || true
  sleep 10
fi

# Test inbox webhook
WEBHOOK_TEST=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" "$N8N_URL/webhook/inbox" \
  -H "Content-Type: application/json" -X POST \
  -d '{"type":"note","title":"Deployment test","description":"Automated deployment verification","priority":"low"}' 2>/dev/null || echo "000")
if [[ "$WEBHOOK_TEST" == "200" ]]; then
  log "  ✅ Webhooks working (test issue created)"
else
  warn "  Webhook test returned HTTP $WEBHOOK_TEST (may need manual verification)"
fi

# Cleanup
rm -f /tmp/n8n_deploy_cookies.txt /tmp/n8n_deploy_hdrs.txt
ok "n8n automation platform deployed successfully"
log "  Dashboard: https://$N8N_HOST (via Authentik SSO)"
log "  Webhook inbox: https://n8n.${WEBHOOK_DOMAIN}/webhook/inbox"
log "  Webhook approve: https://n8n.${WEBHOOK_DOMAIN}/webhook/approve"
log "  All deployments send bugs/features/notes to: https://n8n.${WEBHOOK_DOMAIN}/webhook/inbox"
