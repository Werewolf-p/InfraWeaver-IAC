#!/usr/bin/env bash
# agent-session.sh — open an ephemeral in-cluster agent session.
#
# Gives you, from inside the cluster, the same thing you get over SSH today:
# an agent with your memory, skills and read access to the cluster. The pod is
# created on demand and deleted when you exit — nothing credentialed is left
# running, which is the whole point of doing it this way rather than parking a
# permanent shell behind a URL.
#
#   scripts/agent-session.sh              # interactive agent session
#   scripts/agent-session.sh --shell      # plain shell, no agent
#   scripts/agent-session.sh --keep       # leave the pod up (debugging)
#
# Environment:
#   ANTHROPIC_API_KEY   required for the agent (not needed with --shell)
#   AGENT_MEMORY_REPO   git URL holding ~/.claude (memory, skills, rules).
#                       Cloned on start, committed back on exit.
#   AGENT_MEMORY_TOKEN  token with push rights to that repo (optional; without
#                       it the session is read-only on memory)
#
# Security notes worth keeping when this moves behind the console button:
#   - The ServiceAccount is read-only and cannot read Secrets. A terminal is
#     only as safe as the identity behind it.
#   - The pod runs under PodSecurity "restricted": non-root, no privilege
#     escalation, all capabilities dropped, seccomp RuntimeDefault.
#   - NetworkPolicy blocks egress into the rest of the cluster; only DNS, the
#     Kubernetes API and public HTTPS are reachable.
#   - Nothing here grants write access. Changes go through git and ArgoCD.
set -euo pipefail

NS=infraweaver-agent
MODE=agent
KEEP=0
for a in "$@"; do
  case "$a" in
    --shell) MODE=shell ;;
    --keep)  KEEP=1 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done

kubectl get ns "$NS" >/dev/null 2>&1 || {
  echo "namespace ${NS} missing — apply kubernetes/platform/agent/rbac.yaml first" >&2; exit 1; }

if [ "$MODE" = "agent" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY is not set (use --shell for a plain shell)" >&2; exit 1
fi

# Pod name is unique per session so two people never share a terminal.
POD="agent-$(date +%s)-$$"
cleanup() { [ "$KEEP" = "1" ] || kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> starting session pod ${POD}"
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels:
    app.kubernetes.io/name: agent-session
spec:
  restartPolicy: Never
  serviceAccountName: agent-session
  # Sessions are disposable; never let one outlive the working day.
  activeDeadlineSeconds: 28800
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: agent
      image: docker.io/library/node:22-bookworm
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
      resources:
        requests: { cpu: 200m, memory: 512Mi }
        limits:   { cpu: "2", memory: 2Gi }
      env:
        - { name: HOME, value: /home/session }
        - { name: ANTHROPIC_API_KEY, value: "${ANTHROPIC_API_KEY:-}" }
        - { name: AGENT_MEMORY_REPO, value: "${AGENT_MEMORY_REPO:-}" }
        - { name: AGENT_MEMORY_TOKEN, value: "${AGENT_MEMORY_TOKEN:-}" }
      command: ["bash","-lc"]
      args:
        - |
          set -e
          export PATH="\$HOME/.npm-global/bin:\$PATH"
          mkdir -p "\$HOME/.npm-global/bin"
          npm config set prefix "\$HOME/.npm-global" >/dev/null 2>&1 || true
          echo "installing tools..."
          curl -sSLo "\$HOME/.npm-global/bin/kubectl" \
            "https://dl.k8s.io/release/\$(curl -sSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
            && chmod +x "\$HOME/.npm-global/bin/kubectl" || echo "kubectl install failed"
          npm i -g @anthropic-ai/claude-code >/dev/null 2>&1 || echo "claude CLI install failed (shell still available)"
          # Memory: clone on start so this session knows what earlier ones knew.
          if [ -n "\${AGENT_MEMORY_REPO}" ]; then
            URL="\${AGENT_MEMORY_REPO}"
            [ -n "\${AGENT_MEMORY_TOKEN}" ] && URL="\$(echo "\$URL" | sed "s#https://#https://x-access-token:\${AGENT_MEMORY_TOKEN}@#")"
            git clone --depth 1 "\$URL" "\$HOME/.claude" >/dev/null 2>&1 \
              && echo "memory: cloned" || echo "memory: clone failed (starting empty)"
          fi
          echo "ready."
          sleep infinity
      volumeMounts:
        - { name: home, mountPath: /home/session }
        - { name: tmp,  mountPath: /tmp }
  volumes:
    - name: home
      emptyDir: {}
    - name: tmp
      emptyDir: {}
EOF

echo "==> waiting for the session to be ready"
kubectl -n "$NS" wait --for=condition=Ready "pod/${POD}" --timeout=300s
for i in $(seq 1 60); do
  kubectl -n "$NS" logs "$POD" 2>/dev/null | grep -q "^ready\." && break
  sleep 5
done
kubectl -n "$NS" logs "$POD" 2>/dev/null | tail -3

echo "==> attaching (exit to end the session and delete the pod)"
if [ "$MODE" = "agent" ]; then
  kubectl -n "$NS" exec -it "$POD" -- bash -lc 'export PATH=$HOME/.npm-global/bin:$PATH; claude || bash -l'
else
  kubectl -n "$NS" exec -it "$POD" -- bash -lc 'export PATH=$HOME/.npm-global/bin:$PATH; bash -l'
fi

# Memory: commit back what this session learned.
if [ -n "${AGENT_MEMORY_REPO:-}" ] && [ -n "${AGENT_MEMORY_TOKEN:-}" ]; then
  echo "==> syncing memory back"
  kubectl -n "$NS" exec "$POD" -- bash -lc '
    cd "$HOME/.claude" 2>/dev/null || exit 0
    git add -A && git diff --cached --quiet && { echo "  no changes"; exit 0; }
    git -c user.email=agent@infraweaver -c user.name="in-cluster agent" commit -qm "memory: session update"
    git push -q && echo "  pushed" || echo "  push failed"
  ' || true
fi
