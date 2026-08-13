#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Close the X-Forwarded-For spoofing hole at the Cloudflare edge, and PROVE it
# closed, so the Authentik brute-force reputation lockout can be armed.
#
#   bash scripts/cloudflare-xff-transform.sh --check     # read-only: token, rule, live probe
#   bash scripts/cloudflare-xff-transform.sh --verify    # live probe only (no token needed)
#   bash scripts/cloudflare-xff-transform.sh --dry-run   # print the API call, write nothing
#   bash scripts/cloudflare-xff-transform.sh --apply     # create the rule (prompts)
#   bash scripts/cloudflare-xff-transform.sh --apply --yes
#
# ── THE HOLE, MEASURED ON THIS PLATFORM ──────────────────────────────────────
# 2026-08-13, live, through the Cloudflare edge (not from a doc):
#
#   curl --resolve auth.<domain>:443:<cf-edge-ip> \
#        -H 'X-Forwarded-For: 203.0.113.77' https://auth.<domain>/if/flow/…
#   → authentik-server log: {"remote": "203.0.113.77", …}
#
# Cloudflare APPENDS to a visitor-supplied X-Forwarded-For instead of replacing
# it, Traefik now trusts the Cloudflare edge and passes the chain through
# (core/traefik/values.yaml), and Authentik's ClientIPMiddleware reads ips[0] —
# the FIRST entry, the attacker's. Any unauthenticated caller therefore chooses
# the IP this platform records and scores.
#
# That is harmless only while nothing CONSUMES the score. The moment
# 70-brute-force-reputation.yaml is mounted it becomes a remote DoS on login:
# 21 failed logins carrying `X-Forwarded-For: <victim>` deny that address the
# login flow for 24h, and the attacker picks the victim.
#
# ── WHY THIS SCRIPT REMOVES THE HEADER AND DOES NOT SET IT ───────────────────
# The earlier plan in the blueprint — Transform Rule → Set dynamic
# `X-Forwarded-For` = `ip.src` — cannot be applied. Cloudflare refuses writes to
# the headers that identify the visitor (x-forwarded-for, true-client-ip,
# x-real-ip, x-forwarded-proto):
#   https://developers.cloudflare.com/rules/transform/request-header-modification/
#
# REMOVE is a different matter and is the fix. A remove acts on the request as
# it ARRIVES, so it deletes the visitor-supplied header; Cloudflare then writes
# its own X-Forwarded-For containing the real client IP. The origin ends up with
# a single authoritative value, which is exactly what ips[0] needs.
# Cloudflare's docs claimed removal was impossible too; that was a documentation
# bug, corrected in cloudflare/cloudflare-docs#27811 (PR #28088).
#
# ⚠️ THE FAILURE MODE TO WATCH, AND WHY --verify IS NOT OPTIONAL:
# if the removal were applied AFTER Cloudflare adds its own header, the origin
# would receive NO X-Forwarded-For at all, Traefik would rewrite it from the TCP
# peer, and Authentik would record the Cloudflare EDGE for every visitor again —
# one address shared by thousands of users, with an IP-reputation lockout on top
# of it. `--verify` distinguishes the three outcomes explicitly and refuses to
# call an edge address a pass. Never arm the blueprint on a rule that has not
# been probed.
#
# ── THE TOKEN ────────────────────────────────────────────────────────────────
# The token this platform holds (OpenBao → `cloudflare-api-token`, used by
# external-dns and the console — verified 2026-08-13 to be the SAME token) is
# DNS-scoped: every /rulesets call returns "Authentication error". Ruleset writes
# need their own token:
#
#   Cloudflare dashboard → My Profile → API Tokens → Create Token → Custom token
#     Permissions : Zone → Transform Rules → Edit
#     Zone Resources: Include → Specific zone → <your zone>
#
#   export CF_TRANSFORM_TOKEN=<the new token>
#
# It is used once, by hand. Do NOT add it to OpenBao or to any workload: nothing
# in this platform needs standing edit rights on edge rules, and a token that can
# rewrite request headers at the edge can rewrite them for every host in the
# zone. Revoke it after this script reports a pass.
#
# The equivalent by hand, if you would rather not mint a token:
#   Cloudflare dashboard → the zone → Rules → Transform Rules
#     → Modify Request Header → Create rule
#     → applies to: All incoming requests
#     → Remove → header name: X-Forwarded-For
#   then run `--verify` from this repo.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_NAME="cloudflare-xff"
source "$(dirname "$0")/lib.sh"

RULE_DESCRIPTION="InfraWeaver: drop visitor-supplied X-Forwarded-For (anti-spoof)"
PHASE="http_request_late_transform"
# TEST-NET-3 (RFC 5737). Never routable, so its appearance in a log is proof of
# spoofing rather than a coincidence.
PROBE_IP="203.0.113.77"
PROBE_PATH="/if/flow/default-authentication-flow/"

MODE=""
ASSUME_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   MODE="check" ;;
    --verify)  MODE="verify" ;;
    --dry-run) MODE="dry-run" ;;
    --apply)   MODE="apply" ;;
    --yes|-y)  ASSUME_YES=true ;;
    -h|--help) sed -n '2,74p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
  shift
done
[[ -n "$MODE" ]] || MODE="check"

require_cmd curl jq

# ── Inputs ───────────────────────────────────────────────────────────────────
# Zone id and base domain come from the cluster when they are not in the
# environment, so the common case is zero arguments.
resolve_from_cluster() {
  command -v kubectl >/dev/null 2>&1 || return 0
  [[ -n "${CF_ZONE_ID:-}" ]] && return 0
  local secret_json
  secret_json=$(kubectl get secret -n infraweaver-console infraweaver-console-secret \
                  -o json 2>/dev/null) || return 0
  CF_ZONE_ID=$(jq -r '.data["cf-zone-id"] // empty' <<<"$secret_json" | base64 -d 2>/dev/null || true)
  return 0
}
resolve_from_cluster

if [[ -z "${BASE_DOMAIN:-}" && -f .env ]]; then
  BASE_DOMAIN=$(grep -E '^BASE_DOMAIN=' .env | head -1 | cut -d= -f2- | tr -d '"' || true)
fi
[[ -n "${BASE_DOMAIN:-}" ]] || die "BASE_DOMAIN not set and not found in .env — export BASE_DOMAIN=<your domain>"

AUTH_HOST="auth.${BASE_DOMAIN}"

cf_api() { # cf_api <method> <path> [body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -X "$method" -H "Authorization: Bearer ${CF_TRANSFORM_TOKEN}" -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(--data "$body")
  curl "${args[@]}" "https://api.cloudflare.com/client/v4${path}"
}

# ── The live probe ───────────────────────────────────────────────────────────
# Forces the request through the Cloudflare edge with --resolve, because this
# platform's internal DNS answers auth.<domain> with the Traefik VIP; resolving
# normally from inside the LAN tests a path an attacker does not use and always
# looks safe. Measured 2026-08-13: the same probe recorded 10.0.0.108 over the
# internal path and 203.0.113.77 over the edge.
verify_live() {
  require_cmd dig kubectl
  local cf_ip ua line remote egress rc=0

  cf_ip=$(dig +short @1.1.1.1 "$AUTH_HOST" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
  [[ -n "$cf_ip" ]] || die "could not resolve $AUTH_HOST at a public resolver — is the record proxied?"

  egress=$(curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  ua="iw-xff-probe-$(date +%s)-$RANDOM"

  log "probing $AUTH_HOST via Cloudflare edge $cf_ip with a spoofed X-Forwarded-For: $PROBE_IP"
  curl -s -o /dev/null --max-time 20 \
       --resolve "${AUTH_HOST}:443:${cf_ip}" \
       -H "X-Forwarded-For: ${PROBE_IP}" \
       -A "$ua" \
       "https://${AUTH_HOST}${PROBE_PATH}" || die "probe request failed"

  sleep 5
  line=$(kubectl logs -n authentik deploy/authentik-server --since=3m 2>/dev/null | grep -F "$ua" | tail -1 || true)
  [[ -n "$line" ]] || die "probe reached no authentik-server log line — cannot conclude anything; re-run"
  remote=$(jq -r '.remote // "?"' <<<"$line")

  echo
  echo "  probe user-agent  : $ua"
  echo "  real caller       : ${egress:-unknown}"
  echo "  authentik recorded: $remote"
  echo

  if [[ "$remote" == "$PROBE_IP" ]]; then
    warn "SPOOFABLE — Authentik recorded the attacker-supplied address."
    warn "Do NOT mount authentik-blueprint-brute-force. Apply the rule first."
    rc=1
  elif [[ -n "$egress" && "$remote" == "$egress" ]]; then
    ok "AUTHORITATIVE — the spoofed header was dropped and the real caller was recorded."
    echo "     Step 0b of kubernetes/platform/authentik/manifests/blueprints/70-brute-force-reputation.yaml"
    echo "     may now be closed, and the mount restored in kubernetes/platform/authentik/values.yaml."
  else
    warn "INCONCLUSIVE — recorded '$remote', which is neither the spoof nor this host's public IP."
    warn "If it is a Cloudflare edge address, the origin is receiving NO X-Forwarded-For and every"
    warn "visitor now shares one address: REVERT the rule and do not arm the lockout."
    rc=1
  fi
  return $rc
}

# ── Rule state ───────────────────────────────────────────────────────────────
fetch_entrypoint() {
  [[ -n "${CF_TRANSFORM_TOKEN:-}" ]] || die "CF_TRANSFORM_TOKEN is not set — see the header of this script"
  [[ -n "${CF_ZONE_ID:-}" ]] || die "CF_ZONE_ID is not set and could not be read from the console secret"
  cf_api GET "/zones/${CF_ZONE_ID}/rulesets/phases/${PHASE}/entrypoint"
}

rule_body() {
  jq -nc --arg d "$RULE_DESCRIPTION" '{
    action: "rewrite",
    action_parameters: { headers: { "X-Forwarded-For": { operation: "remove" } } },
    expression: "true",
    description: $d,
    enabled: true
  }'
}

report_rules() {
  local resp="$1" msg
  if [[ "$(jq -r '.success' <<<"$resp")" != "true" ]]; then
    msg=$(jq -r '[.errors[]?.message] | join("; ")' <<<"$resp")
    if [[ "$msg" == *"Authentication error"* ]]; then
      warn "token cannot read $PHASE rulesets: $msg"
      warn "it needs Zone → Transform Rules → Edit (the platform's DNS token is not enough)"
    elif [[ "$msg" == *"not find"* || "$msg" == *"not found"* ]]; then
      log "no $PHASE ruleset exists on this zone yet — --apply will create it"
      return 0
    else
      warn "unexpected API response: $msg"
    fi
    return 1
  fi
  echo "  existing $PHASE rules:"
  jq -r '.result.rules[]? | "    - \(.description // "(no description)")  [\(.action)] enabled=\(.enabled)"' <<<"$resp"
  if jq -e '.result.rules[]? | select(.action_parameters.headers["X-Forwarded-For"])' <<<"$resp" >/dev/null 2>&1; then
    ok "an X-Forwarded-For rule is already present"
  else
    warn "no X-Forwarded-For rule present — the spoofing hole is open"
  fi
  return 0
}

case "$MODE" in
  verify)
    verify_live
    ;;

  check)
    log "zone=${CF_ZONE_ID:-<unset>} host=$AUTH_HOST"
    if [[ -n "${CF_TRANSFORM_TOKEN:-}" ]]; then
      report_rules "$(fetch_entrypoint)" || true
    else
      warn "CF_TRANSFORM_TOKEN not set — skipping the rule read (see the header for how to mint one)"
    fi
    verify_live
    ;;

  dry-run)
    echo "POST https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID:-<zone>}/rulesets/<ruleset-id>/rules"
    rule_body | jq .
    echo
    echo "(or PUT /zones/<zone>/rulesets/phases/${PHASE}/entrypoint with {\"rules\":[…]} when no ruleset exists yet)"
    ;;

  apply)
    resp=$(fetch_entrypoint)
    if jq -e '.result.rules[]? | select(.action_parameters.headers["X-Forwarded-For"])' <<<"$resp" >/dev/null 2>&1; then
      ok "rule already exists — nothing to create"
      verify_live
      exit $?
    fi

    if ! $ASSUME_YES; then
      echo "About to add to zone ${CF_ZONE_ID} (${PHASE}):"
      rule_body | jq .
      read -r -p "Proceed? [y/N] " a; [[ "$a" == "y" || "$a" == "Y" ]] || die "aborted"
    fi

    if [[ "$(jq -r '.success' <<<"$resp")" == "true" ]]; then
      rsid=$(jq -r '.result.id' <<<"$resp")
      log "appending the rule to existing ruleset $rsid"
      out=$(cf_api POST "/zones/${CF_ZONE_ID}/rulesets/${rsid}/rules" "$(rule_body)")
    else
      log "creating the $PHASE entrypoint ruleset"
      out=$(cf_api PUT "/zones/${CF_ZONE_ID}/rulesets/phases/${PHASE}/entrypoint" \
              "$(jq -nc --argjson r "$(rule_body)" '{rules: [$r]}')")
    fi

    if [[ "$(jq -r '.success' <<<"$out")" != "true" ]]; then
      jq -r '[.errors[]? | "\(.code): \(.message)"] | .[]' <<<"$out" >&2
      die "Cloudflare rejected the rule"
    fi
    ok "rule created"

    log "waiting 10s for the edge to pick it up, then probing"
    sleep 10
    verify_live
    ;;
esac
