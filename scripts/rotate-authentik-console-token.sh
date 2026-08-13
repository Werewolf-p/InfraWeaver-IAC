#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Rotate `iw-console-api-token` — the Authentik API token the console uses for
# /core/* and /events/*.
#
# Replaces the manual, root-token-gated sequence recorded in
# docs/BREAK-GLASS.md §10. Same steps, same invariants, one command.
#
#   bash scripts/rotate-authentik-console-token.sh --check     # read-only status
#   bash scripts/rotate-authentik-console-token.sh --dry-run   # plan, no writes
#   bash scripts/rotate-authentik-console-token.sh             # rotate (prompts)
#   bash scripts/rotate-authentik-console-token.sh --yes       # rotate, no prompt
#
# ── THE ROTATION INVARIANT ───────────────────────────────────────────────────
# The token's IDENTIFIER must stay `iw-console-api-token`. The console's expiry
# metric looks the token up by that exact identifier, so a renamed replacement
# works fine but blinds both expiry alerts and raises
# AuthentikConsoleTokenUnobservable instead. This script therefore rotates the
# KEY of the existing Token row in place and never creates a second token —
# the identifier, intent, owner and description cannot drift by construction.
#
# ── A CONSOLE RESTART IS REQUIRED, AND THAT IS NOT AVOIDABLE HERE ────────────
# The console consumes the token as an ENV VAR:
#     kubernetes/catalog/infraweaver-console/base/deployment.yaml:327-331
#     AUTHENTIK_TOKEN <- secretKeyRef infraweaver-console-secret/authentik-token
# and reads it as `process.env.AUTHENTIK_TOKEN` at request time
# (apps/infraweaver-console/src/lib/authentik.ts, lib/sso/authentik-client.ts).
# Kubernetes injects secretKeyRef env vars ONCE, at container start; updating
# the Secret does not update the environment of a running pod. So ESO
# re-syncing the Secret is necessary but NOT sufficient, and this script always
# does a rollout restart. (A mounted-file + read-at-use design would remove the
# restart; that is a code change, deliberately not made here — see §10 of
# docs/BREAK-GLASS.md for the follow-up.)
# The restart is a zero-downtime rolling update; the only user-visible effect
# is a brief window in which console→Authentik calls fail while the old key is
# already dead and the new pod is not yet serving.
#
# ── ORDERING, AND WHY IT IS THIS WAY ROUND ───────────────────────────────────
# The new key is written to OpenBao BEFORE it is applied in Authentik. If the
# OpenBao write fails, Authentik still holds the OLD key and the running
# console keeps working — nothing is broken and the operator can retry. The
# reverse order would kill every console→Authentik call the instant Authentik
# was updated, whether or not the rest of the sequence succeeded.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

IDENTIFIER="iw-console-api-token"
EXPECTED_OWNER="svc-infraweaver-console"
AK_NS="authentik"
OPENBAO_NS="openbao"
CONSOLE_NS="infraweaver-console"
CONSOLE_DEPLOY="infraweaver-console"
EXTERNALSECRET="infraweaver-console-secret"
SECRET_NAME="infraweaver-console-secret"
SECRET_KEY="authentik-token"
BAO_MOUNT="secret"
BAO_PATH="platform/infraweaver-console"
LIFETIME_DAYS=365

MODE="rotate"
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --check)   MODE="check" ;;
    --dry-run) MODE="dryrun" ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --lifetime-days=*) LIFETIME_DAYS="${arg#*=}" ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[36m[rotate-ak-token]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[rotate-ak-token]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[rotate-ak-token] %s\033[0m\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { err "missing required tool: $1"; exit 1; }; }
need kubectl; need jq; need sha256sum

ak_worker() {
  kubectl -n "$AK_NS" get pod -l app.kubernetes.io/name=authentik,app.kubernetes.io/component=worker \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Run a snippet in `ak shell` and return only what it prints between markers.
# `ak shell` writes structured startup logs to stdout, so markers are the only
# reliable way to separate a value from the noise.
ak_eval() { # stdin: python; stdout: marked payload
  local worker="$1" snippet
  snippet="$(cat)"
  kubectl -n "$AK_NS" exec -i "$worker" -- ak shell -c "$snippet" 2>/dev/null \
    | grep -o 'AKOUT<<.*>>AKOUT' | sed 's/^AKOUT<<//; s/>>AKOUT$//'
}

root_token() {
  kubectl -n "$OPENBAO_NS" get secret openbao-unseal -o jsonpath='{.data.root_token}' | base64 -d
}

# ── 1. Preflight ─────────────────────────────────────────────────────────────
WORKER="$(ak_worker)"
[ -n "$WORKER" ] || { err "no authentik worker pod found in ns/$AK_NS"; exit 1; }
log "authentik worker: $WORKER"

STATUS_JSON="$(ak_eval "$WORKER" <<PY
import json
from authentik.core.models import Token
t = Token.objects.filter(identifier="${IDENTIFIER}").first()
out = {"found": bool(t)}
if t:
    out.update(intent=str(t.intent), expiring=bool(t.expiring),
               expires=str(t.expires), user=t.user.username,
               key_sha256_prefix=__import__("hashlib").sha256(t.key.encode()).hexdigest()[:16])
print("AKOUT<<" + json.dumps(out) + ">>AKOUT")
PY
)"
[ -n "$STATUS_JSON" ] || { err "could not query Authentik for the token (ak shell produced no output)"; exit 1; }

if [ "$(jq -r .found <<<"$STATUS_JSON")" != "true" ]; then
  err "no token with identifier '$IDENTIFIER' exists."
  err "This script ROTATES an existing token; it deliberately does not create one,"
  err "because creating it also decides owner/intent. See docs/BREAK-GLASS.md §10."
  exit 1
fi

CUR_OWNER="$(jq -r .user <<<"$STATUS_JSON")"
log "token found  : identifier=$IDENTIFIER owner=$CUR_OWNER intent=$(jq -r .intent <<<"$STATUS_JSON")"
log "current expiry: $(jq -r .expires <<<"$STATUS_JSON")  (expiring=$(jq -r .expiring <<<"$STATUS_JSON"))"
log "current key   : sha256:$(jq -r .key_sha256_prefix <<<"$STATUS_JSON")…"

if [ "$CUR_OWNER" != "$EXPECTED_OWNER" ]; then
  err "owner is '$CUR_OWNER', expected '$EXPECTED_OWNER' — refusing to rotate a token"
  err "whose ownership has drifted. Investigate before continuing."
  exit 1
fi

LIVE_SHA="$(kubectl -n "$CONSOLE_NS" get secret "$SECRET_NAME" \
  -o jsonpath="{.data.$SECRET_KEY}" 2>/dev/null | base64 -d | tr -d '\n' | sha256sum | cut -c1-16)"
log "k8s Secret key: sha256:${LIVE_SHA}…"
if [ "$LIVE_SHA" != "$(jq -r .key_sha256_prefix <<<"$STATUS_JSON")" ]; then
  err "WARNING: the key in Authentik and the key in $CONSOLE_NS/$SECRET_NAME DIFFER."
  err "The console is running on a credential Authentik does not accept, or a"
  err "previous rotation was interrupted. Rotating will fix it; be aware that is"
  err "what you are doing."
fi

if [ "$MODE" = "check" ]; then
  ok "check complete — no changes made."
  exit 0
fi

# ── 2. Plan ──────────────────────────────────────────────────────────────────
NEW_EXPIRY_HUMAN="$(date -u -d "+${LIFETIME_DAYS} days" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "+${LIFETIME_DAYS}d")"
cat <<PLAN

  Plan
  ────
   1. generate a new 60-char key with Authentik's own default_token_key()
   2. write it to OpenBao   ${BAO_MOUNT}/${BAO_PATH} → ${SECRET_KEY}   (kv patch, value on stdin)
   3. apply it in Authentik: Token(identifier=${IDENTIFIER}).key = <new>
                             expires = ${NEW_EXPIRY_HUMAN}   (expiring=True)
   4. force-sync ExternalSecret ${CONSOLE_NS}/${EXTERNALSECRET} and wait for the
      Kubernetes Secret to actually carry the new value
   5. rollout restart deploy/${CONSOLE_DEPLOY} (REQUIRED — env var, see header)
   6. verify /core/users/me/ from inside a running console pod

  Identifier stays ${IDENTIFIER}. No second token is created.

PLAN

if [ "$MODE" = "dryrun" ]; then
  ok "dry run — nothing was changed."
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Proceed? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) log "aborted."; exit 0 ;; esac
fi

# ── 3. Generate (pure function — does NOT touch the database) ────────────────
NEW_KEY="$(ak_eval "$WORKER" <<'PY'
from authentik.core.models import default_token_key
print("AKOUT<<" + default_token_key() + ">>AKOUT")
PY
)"
[ ${#NEW_KEY} -ge 40 ] || { err "generated key looks wrong (length ${#NEW_KEY}); aborting before any write"; exit 1; }
NEW_SHA="$(printf '%s' "$NEW_KEY" | sha256sum | cut -c1-16)"
log "generated new key: sha256:${NEW_SHA}…"

# ── 4. OpenBao FIRST (see ordering note in the header) ───────────────────────
# `patch`, never `put`: this path holds ~28 unrelated console credentials and
# the ExternalSecret is creationPolicy:Owner + deletionPolicy:Retain, so one
# lost property fails the WHOLE secret and freezes every other key with it.
# `<name>=-` reads the value from stdin so it never reaches argv, ps, or history.
BEFORE_VERSION="$(kubectl -n "$OPENBAO_NS" exec openbao-0 -c openbao -- \
  env VAULT_TOKEN="$(root_token)" VAULT_ADDR=http://127.0.0.1:8200 \
  bao kv get -format=json -mount="$BAO_MOUNT" "$BAO_PATH" | jq -r '.data.metadata.version')"
log "OpenBao current version: $BEFORE_VERSION"

printf '%s' "$NEW_KEY" | kubectl -n "$OPENBAO_NS" exec -i openbao-0 -c openbao -- \
  env VAULT_TOKEN="$(root_token)" VAULT_ADDR=http://127.0.0.1:8200 \
  bao kv patch -mount="$BAO_MOUNT" "$BAO_PATH" "${SECRET_KEY}=-" >/dev/null

AFTER_JSON="$(kubectl -n "$OPENBAO_NS" exec openbao-0 -c openbao -- \
  env VAULT_TOKEN="$(root_token)" VAULT_ADDR=http://127.0.0.1:8200 \
  bao kv get -format=json -mount="$BAO_MOUNT" "$BAO_PATH")"
AFTER_VERSION="$(jq -r '.data.metadata.version' <<<"$AFTER_JSON")"
AFTER_KEYCOUNT="$(jq -r '.data.data | keys | length' <<<"$AFTER_JSON")"
if [ "$AFTER_VERSION" -le "$BEFORE_VERSION" ]; then
  err "OpenBao version did not increase ($BEFORE_VERSION -> $AFTER_VERSION): the write did not happen."
  err "NOTHING has changed in Authentik; the console is unaffected. Safe to retry."
  exit 1
fi
ok "OpenBao written: version $BEFORE_VERSION -> $AFTER_VERSION, $AFTER_KEYCOUNT properties intact"

# ── 5. Apply in Authentik ────────────────────────────────────────────────────
APPLIED="$(printf '%s' "$NEW_KEY" | kubectl -n "$AK_NS" exec -i "$WORKER" -- sh -c '
NEW_KEY=$(cat) ak shell -c "
import os, json
from datetime import timedelta
from django.utils.timezone import now
from authentik.core.models import Token
t = Token.objects.get(identifier=\"'"$IDENTIFIER"'\")
t.key = os.environ[\"NEW_KEY\"]
t.expiring = True
t.expires = now() + timedelta(days='"$LIFETIME_DAYS"')
t.save()
print(\"AKOUT<<\" + json.dumps({\"expires\": str(t.expires)}) + \">>AKOUT\")
"' 2>/dev/null | grep -o 'AKOUT<<.*>>AKOUT' | sed 's/^AKOUT<<//; s/>>AKOUT$//')"

if [ -z "$APPLIED" ]; then
  err "FAILED to apply the new key in Authentik."
  err "OpenBao now holds a key Authentik does not know. The running console is"
  err "STILL WORKING on the old key, but will break at its next restart or when"
  err "ESO re-syncs (refreshInterval 1h). Re-run this script to converge."
  exit 1
fi
ok "Authentik updated: new expiry $(jq -r .expires <<<"$APPLIED")"

# ── 6. ESO re-sync, and WAIT for the Secret to really carry the new value ────
kubectl -n "$CONSOLE_NS" annotate externalsecret "$EXTERNALSECRET" \
  force-sync="$(date +%s)" --overwrite >/dev/null
log "waiting for $CONSOLE_NS/$SECRET_NAME to carry the new value…"
for _ in $(seq 1 60); do
  cur="$(kubectl -n "$CONSOLE_NS" get secret "$SECRET_NAME" \
    -o jsonpath="{.data.$SECRET_KEY}" 2>/dev/null | base64 -d | tr -d '\n' | sha256sum | cut -c1-16)"
  [ "$cur" = "$NEW_SHA" ] && break
  sleep 2
done
if [ "$cur" != "$NEW_SHA" ]; then
  err "the Kubernetes Secret still does not match the new key after 120s."
  err "Check: kubectl -n $CONSOLE_NS describe externalsecret $EXTERNALSECRET"
  exit 1
fi
ok "Secret synced: sha256:${NEW_SHA}…"

# ── 7. Restart (REQUIRED — secretKeyRef env vars are injected once, at start) ─
log "restarting deploy/$CONSOLE_DEPLOY (required: AUTHENTIK_TOKEN is an env var)…"
kubectl -n "$CONSOLE_NS" rollout restart "deploy/$CONSOLE_DEPLOY" >/dev/null
kubectl -n "$CONSOLE_NS" rollout status "deploy/$CONSOLE_DEPLOY" --timeout=300s

# ── 8. Prove it from inside a running console pod ────────────────────────────
POD="$(kubectl -n "$CONSOLE_NS" get pod -l app="$CONSOLE_DEPLOY" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "$POD" ]; then
  # `node`, not `curl` — the console image has no curl (verified 2026-08-13:
  # node v20 and busybox wget are present, curl is not). `-c console` is
  # explicit because the pod also runs a connector-git-sync sidecar.
  # The token is read from the pod's own env, so it never crosses this shell.
  WHOAMI="$(kubectl -n "$CONSOLE_NS" exec "$POD" -c console -- node -e '
    fetch(process.env.AUTHENTIK_URL + "/api/v3/core/users/me/", {
      headers: { Authorization: "Bearer " + process.env.AUTHENTIK_TOKEN },
    }).then(r => r.json())
      .then(j => console.log(JSON.stringify({ username: j?.user?.username ?? null })))
      .catch(e => console.log(JSON.stringify({ username: null, error: String(e) })));
  ' 2>/dev/null | jq -r '.username // empty')"
  if [ "$WHOAMI" = "$EXPECTED_OWNER" ]; then
    ok "verified from pod $POD: /core/users/me/ -> $WHOAMI"
  else
    err "post-rotation verification did not return '$EXPECTED_OWNER' (got: '${WHOAMI:-<none>}')."
    err "The rotation itself completed; investigate the console's Authentik connectivity."
    exit 1
  fi
else
  err "no console pod found to verify against — verify manually before closing out."
fi

# ── 9. Two-token baseline (docs/BREAK-GLASS.md §10) ──────────────────────────
log "live Authentik token inventory (expect exactly these two):"
ak_eval "$WORKER" <<'PY' | jq -r '.[] | "  \(.identifier)  intent=\(.intent)  expiring=\(.expiring)  expires=\(.expires)  owner=\(.user)"'
import json
from authentik.core.models import Token
print("AKOUT<<" + json.dumps([
    {"identifier": t.identifier, "intent": str(t.intent), "expiring": bool(t.expiring),
     "expires": str(t.expires), "user": t.user.username}
    for t in Token.objects.all().order_by("identifier")
]) + ">>AKOUT")
PY

ok "rotation complete. Identifier preserved: $IDENTIFIER"
log "The expiry alerts in kubernetes/monitoring/alerts/authentik-token.yaml key off"
log "that identifier, so they should return to green on the next scrape."
