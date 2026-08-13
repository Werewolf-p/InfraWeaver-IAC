#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Make every WordPress site see the REAL visitor instead of a Cloudflare edge —
# and be able to switch that off again in one command.
#
#   bash scripts/wp-trust-cloudflare-ips.sh --status   # what each site trusts today
#   bash scripts/wp-trust-cloudflare-ips.sh --on       # trust Cloudflare hops
#   bash scripts/wp-trust-cloudflare-ips.sh --off      # stop trusting them
#   bash scripts/wp-trust-cloudflare-ips.sh --verify <host>   # prove it end-to-end
#
# ── WHAT IS WRONG WITHOUT THIS ───────────────────────────────────────────────
# The official `wordpress:*-apache` image enables mod_remoteip with
# `RemoteIPHeader X-Forwarded-For` and trusts RFC1918 only. A request arrives at
# the origin as `<visitor>, <cloudflare-edge>`: Cloudflare writes the visitor,
# then Traefik — which trusts Cloudflare's ranges on web/websecure — appends its
# own peer, that edge. mod_remoteip walks right-to-left while the address is
# trusted, the edge is not, so it stops there and hands PHP a Cloudflare address
# as REMOTE_ADDR.
#
# Measured on the live fleet 2026-08-13: a request from a residential address was
# logged by the site as a Cloudflare address. Every plugin that blocks, throttles
# or logs "the client" therefore sees the whole visitor population as a handful
# of Cloudflare addresses — an IP block that blocks an edge, or nothing at all.
#
# ── WHY THIS IS NOT A TRAEFIK MIDDLEWARE ─────────────────────────────────────
# It cannot be. Traefik's headers middleware sets STATIC values; it has no way to
# copy CF-Connecting-IP (or anything else) into another header, and no way to
# rewrite the X-Forwarded-For chain it just appended to. Nothing between the edge
# and Apache can decide this. The trust list has to live where the address is
# consumed, which is mod_remoteip.
#
# ⚠️ SAFE ONLY WHILE THE EDGE STRIPS INBOUND XFF ─────────────────────────────
# Trusting these ranges is correct only because the Cloudflare Transform Rule
# REMOVES a visitor-supplied X-Forwarded-For (scripts/cloudflare-xff-transform.sh).
# If that rule is ever deleted, any caller could put whatever they liked in front
# of the chain and choose the address the site blocks and logs. That is strictly
# worse than logging the edge — so if the rule goes, run `--off` FIRST.
# `--on` therefore refuses to run until it has re-proved the edge behaviour.
#
# ── HOW THE TOGGLE WORKS ─────────────────────────────────────────────────────
# The mount never changes. `--off` rewrites the ConfigMap to a comment-only file
# and restarts the pods, so the site is back to the stock behaviour without any
# manifest edit — and `--on` puts the directives back the same way. The console
# emits the same ConfigMap for new sites and honours the same switch through
# WORDPRESS_TRUST_CLOUDFLARE_IPS (default on); see the addon's manifest.ts.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_NAME="wp-trust-cf"
source "$(dirname "$0")/lib.sh"

NS="${WORDPRESS_NAMESPACE:-wordpress}"
KEY="zz-remoteip-cloudflare.conf"
MOUNT="/etc/apache2/conf-enabled/${KEY}"
VOL="apache-conf"

MODE=""
VERIFY_HOST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) MODE="status" ;;
    --on)     MODE="on" ;;
    --off)    MODE="off" ;;
    --verify) MODE="verify"; VERIFY_HOST="${2:-}"; shift ;;
    -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
  shift
done
[[ -n "$MODE" ]] || MODE="status"

require_cmd kubectl curl

# Cloudflare's own published lists, fetched at run time so this never applies a
# stale range. A fetch failure aborts rather than applying a truncated list: a
# missing range silently returns those visitors to being logged as the edge.
fetch_ranges() {
  local v4 v6
  v4=$(curl -fsSL --max-time 20 https://www.cloudflare.com/ips-v4) || die "could not fetch ips-v4"
  v6=$(curl -fsSL --max-time 20 https://www.cloudflare.com/ips-v6) || die "could not fetch ips-v6"
  printf '%s\n%s\n' "$v4" "$v6" | grep -E '^[0-9a-fA-F.:]+/[0-9]+$'
}

conf_on() {
  local ranges="$1"
  echo "# Managed by InfraWeaver — scripts/wp-trust-cloudflare-ips.sh"
  echo "# Extends the image's conf-enabled/remoteip.conf (loaded earlier, lexically)."
  echo "# Trusted = a hop to skip when deciding who the client is. Valid ONLY while"
  echo "# the Cloudflare Transform Rule strips a visitor-supplied X-Forwarded-For."
  echo "RemoteIPHeader X-Forwarded-For"
  while read -r r; do [[ -n "$r" ]] && echo "RemoteIPTrustedProxy $r"; done <<<"$ranges"
}

conf_off() {
  echo "# Managed by InfraWeaver — DISABLED via scripts/wp-trust-cloudflare-ips.sh --off"
  echo "# Sites are back to the stock image behaviour: the Cloudflare edge is recorded"
  echo "# as the client. Re-enable with --on once the edge strips inbound XFF again."
}

# ⚠️ SELECT BY "not the database", NOT by component=wordpress. A blue/green site
# runs a second Deployment labelled `wordpress-slot-b`, and the Service can be
# pointing at THAT one — measured 2026-08-13, `lol`'s Service selected
# `wordpress-slot-b`. A component=wordpress selector patches slot A, reports
# success, and leaves the deployment actually serving the public untouched.
NOT_DB="infraweaver.io/component notin (db)"

sites() {
  kubectl get deploy -n "$NS" -l "$NOT_DB" \
    -o jsonpath='{range .items[*]}{.metadata.labels.infraweaver\.io/site}{"\n"}{end}' 2>/dev/null \
    | sort -u | grep -v '^$'
}

wp_deploys_for() { # every slot of one site
  # ONE -l: kubectl keeps only the last --selector it is given, so passing two
  # silently drops the site filter and returns the whole namespace. That looked
  # like "7/9 mounted" for every site on first run.
  kubectl get deploy -n "$NS" -l "infraweaver.io/site=$1,$NOT_DB" -o name
}

# How many of this site's WordPress Deployments actually carry the mount. A
# ConfigMap that exists while a slot does not mount it is the same lie as no
# ConfigMap at all, so --status counts mounts rather than trusting the object.
mounted_count() {
  local n=0 d
  for d in $(wp_deploys_for "$1"); do
    kubectl get "$d" -n "$NS" -o json | grep -q "\"$VOL\"" && n=$((n + 1))
  done
  echo "$n"
}

# Probe a public site through the Cloudflare edge and report what its own access
# log recorded. The --resolve is load-bearing: internal DNS answers these hosts
# with the Traefik VIP, and that path never touches Cloudflare, so a probe
# without it tests something no visitor does and always looks correct.
verify_host() {
  local host="$1"
  require_cmd dig
  [[ -n "$host" ]] || die "--verify needs a host, e.g. --verify example.com"
  local cf_ip ua egress line seen pod
  cf_ip=$(dig +short @1.1.1.1 "$host" | grep -E '^[0-9]+\.' | head -1) || true
  [[ -n "$cf_ip" ]] || die "$host does not resolve publicly — is it proxied?"
  egress=$(curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  ua="iw-remoteip-probe-$(date +%s)-$RANDOM"

  # Cache-busting query: a Cloudflare HIT never reaches the origin, and this
  # check would then report "no pod logged the probe" for a site that is fine.
  curl -s -o /dev/null --max-time 20 --resolve "${host}:443:${cf_ip}" \
       -H "X-Forwarded-For: 203.0.113.77" -A "$ua" "https://${host}/?iw-probe=${RANDOM}" || die "probe failed"
  sleep 4

  # $NOT_DB, not component=wordpress: the Service may be pointing at slot B, and
  # a probe that only reads slot A's log concludes nothing while sounding certain.
  pod=$(kubectl get pods -n "$NS" -l "$NOT_DB" \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read -r p; do
          if kubectl logs -n "$NS" "$p" -c wordpress --since=120s 2>/dev/null | grep -qF "$ua"; then echo "$p"; break; fi
        done)
  [[ -n "$pod" ]] || die "no pod logged the probe — wrong host, or the site is not on this cluster"
  line=$(kubectl logs -n "$NS" "$pod" -c wordpress --since=120s | grep -F "$ua" | tail -1)
  seen=$(awk '{print $1}' <<<"$line")

  echo "  pod              : $pod"
  echo "  real caller      : ${egress:-unknown}"
  echo "  site recorded    : $seen"
  if [[ "$seen" == "203.0.113.77" ]]; then
    warn "SPOOFABLE — the site took the header the caller sent. Run --off and fix the edge rule."
    return 1
  elif [[ -n "$egress" && "$seen" == "$egress" ]]; then
    ok "AUTHORITATIVE — the site recorded the real visitor."
    return 0
  fi
  warn "recorded '$seen' — neither the spoof nor this host's address (a Cloudflare edge means trust is OFF or incomplete)"
  return 1
}

case "$MODE" in
  status)
    printf '%-22s %-10s %s\n' "SITE" "MOUNTED" "APACHE TRUSTS"
    for s in $(sites); do
      total=$(wp_deploys_for "$s" | wc -l)
      mounts="$(mounted_count "$s")/$total"
      body=$(kubectl get cm -n "$NS" "${s}-apache-conf" -o jsonpath="{.data.${KEY//./\\.}}" 2>/dev/null || true)
      if [[ -z "$body" ]]; then
        printf '%-22s %-10s %s\n' "$s" "$mounts" "no ConfigMap — stock behaviour (the edge is the client)"
      elif grep -q "RemoteIPTrustedProxy" <<<"$body"; then
        printf '%-22s %-10s %s\n' "$s" "$mounts" "ON ($(grep -c RemoteIPTrustedProxy <<<"$body") ranges)"
      else
        printf '%-22s %-10s %s\n' "$s" "$mounts" "OFF (explicitly disabled)"
      fi
    done
    ;;

  on|off)
    if [[ "$MODE" == "on" ]]; then
      log "re-checking that the edge strips inbound X-Forwarded-For before trusting it"
      "$(dirname "$0")/cloudflare-xff-transform.sh" --verify >/dev/null 2>&1 \
        || die "the edge check did not pass — trusting Cloudflare now would let callers choose their own IP. Fix that first."
      ok "edge check passed"
      body=$(conf_on "$(fetch_ranges)")
      log "applying $(grep -c RemoteIPTrustedProxy <<<"$body") trusted ranges"
    else
      body=$(conf_off)
      warn "disabling: sites will record the Cloudflare edge as the client again"
    fi

    for s in $(sites); do
      kubectl create configmap "${s}-apache-conf" -n "$NS" --from-file="${KEY}=/dev/stdin" \
        --dry-run=client -o yaml <<<"$body" | kubectl apply -f - >/dev/null
      kubectl label cm "${s}-apache-conf" -n "$NS" "infraweaver.io/site=$s" --overwrite >/dev/null
      for d in $(wp_deploys_for "$s"); do
        # Add the volume + mount only if this Deployment predates them. A site the
        # console already renders with them is left byte-identical, so nothing
        # restarts that does not need to.
        if ! kubectl get "$d" -n "$NS" -o json | grep -q "\"$VOL\""; then
          kubectl patch "$d" -n "$NS" --type=json -p "[
            {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes/-\",\"value\":{\"name\":\"$VOL\",\"configMap\":{\"name\":\"${s}-apache-conf\"}}},
            {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/-\",\"value\":{\"name\":\"$VOL\",\"mountPath\":\"$MOUNT\",\"subPath\":\"$KEY\",\"readOnly\":true}}
          ]" >/dev/null
          log "$s: mounted"
        else
          # The file changed under an existing mount; Apache only reads it at start.
          kubectl rollout restart "$d" -n "$NS" >/dev/null
          log "$s: restarted"
        fi
      done
    done
    ok "$MODE applied to every site — give the pods a moment, then --verify <host>"
    ;;

  verify) verify_host "$VERIFY_HOST" ;;
esac
