# syntax=docker/dockerfile:1
#
# agent-shell — the image both in-cluster terminals run.
#
# WHY THIS IMAGE EXISTS. Both shells previously ran stock `node:22-bookworm` and
# curled a ttyd release binary into $HOME at pod start. That had three defects
# this image fixes and one it cannot:
#
#   1. ttyd 1.7.7 is the newest RELEASE and is from 2024-03-30 — ~2y5m old.
#      Shell-injection hardening (open_uri refactor, #1498), sprintf→snprintf,
#      zlib/libwebsockets bumps and the mobile viewport fix all sit UNRELEASED on
#      main. We build from a pinned main commit instead of waiting for a release.
#   2. No tmux, and the container runs as uid 1000 with no apt, so persistence
#      was impossible at runtime. ttyd SIGHUPs on disconnect, so a browser
#      refresh started a NEW shell and killed whatever was running — the single
#      worst property of the old setup.
#   3. Installing at pod start means every restart depends on GitHub being up
#      and on egress that the shell should not need.
#
# What it cannot fix: the shell's own privileges. Those live in RBAC, not here.
#
# ⚠️ TTYD_REF IS A PINNED COMMIT, NOT A BRANCH. Building from `main` would make
# the image unreproducible and would silently adopt whatever landed upstream.
# Bump it deliberately, and read the diff when you do — this binary is the thing
# an authenticated browser session talks to.

# ── build ttyd from source ──────────────────────────────────────────────────
FROM debian:bookworm-slim AS ttyd-build

# 2026-08-12 "html: add viewport meta tag for mobile browsers (#1564)".
# Chosen over tag v1.7.7 (2024-03-30) precisely because of what landed after it.
ARG TTYD_REF=2922cb89f518bae4d0fcf4d757a7419638fc71fc

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates \
      libjson-c-dev libwebsockets-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/tsl0922/ttyd.git /src \
    && cd /src \
    && git checkout "${TTYD_REF}" \
    && git rev-parse HEAD > /ttyd.commit \
    && mkdir build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && make -j"$(nproc)" \
    && strip ttyd

# ── runtime ─────────────────────────────────────────────────────────────────
FROM node:22-bookworm

# tmux      — session persistence. `tmux new -A -s ops` reattaches on refresh
#             instead of starting over. This is the reason the image exists.
# asciinema — session recording in asciicast, which is plain NDJSON: greppable,
#             diffable, and replayable by a self-hosted player. Beats `script`'s
#             typescript+timing pair, and far beats video or base64.
# util-linux — keeps `script` available as the fallback path.
# The rest is what an operator shell needs and the old startup script installed
# at runtime or simply lacked.
#
# ⚠️ libwebsockets-evlib-uv IS LOAD-BEARING AND WAS MISSING. WITHOUT IT THE
# ttyd IN THIS IMAGE CANNOT START AT ALL. Debian ships libwebsockets built with
# LWS_WITH_EVLIB_PLUGINS=ON, so the libuv event loop lives in a SEPARATE package
# that `libwebsockets17` does not depend on. ttyd links libuv and asks lws for
# that loop, so lws dlopen()s the plugin and, not finding it, aborts before
# binding a port:
#
#     E: lws_create_context: unable to load evlib plugin evlib_uv
#     E: libwebsockets context creation failed
#
# The build stage never caught this because `libwebsockets-dev` pulls the plugin
# in transitively, and the old smoke test below only ran `ttyd --version`, which
# returns before any context is created. Measured 2026-08-16: the published
# image `agentshell-20260815-210057` fails this way on every invocation. The
# pods only appeared healthy because `$HOME/bin` precedes /usr/local/bin on PATH
# and the persistent home volume still carried the curl-installed ttyd 1.7.7
# release binary from before this image existed — i.e. the ~2.5-year-old release
# this whole image was built to stop running. Both Deployments now invoke
# /usr/local/bin/ttyd by ABSOLUTE PATH so the PVC can never shadow it again.
#
# vim + nano: an operator with no editor falls back to SSH for any real work,
# which defeats the point of an in-cluster shell. vim-tiny (what was here) does
# not provide `vim` and has no syntax highlighting, no multi-level undo and no
# visual mode. Two editors rather than one because "which editor" is a genuine
# preference and neither is large.
RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux asciinema util-linux \
      git curl ca-certificates jq less procps iputils-ping dnsutils \
      vim nano \
      libjson-c5 libwebsockets17 libwebsockets-evlib-uv zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ttyd-build /src/build/ttyd /usr/local/bin/ttyd
COPY --from=ttyd-build /ttyd.commit /usr/local/share/ttyd.commit

# Fail the BUILD, not a 3am session, if the binary is not runnable.
#
# ⚠️ `--version` IS NOT A SMOKE TEST AND NEVER WAS. It parses argv and exits
# before lws_create_context(), so it passed for the entire life of the image
# that could not start. The check below BINDS A PORT and makes a real request,
# which is the smallest test that would have caught the missing evlib plugin.
RUN /usr/local/bin/ttyd --version && tmux -V && asciinema --version \
 && ( /usr/local/bin/ttyd -p 7699 -i 127.0.0.1 true & echo $! > /tmp/ttyd.pid ) \
 && for i in $(seq 1 20); do curl -fsS -o /dev/null http://127.0.0.1:7699/ && break || sleep 0.5; done \
 && curl -fsS -o /dev/null http://127.0.0.1:7699/ \
 && kill "$(cat /tmp/ttyd.pid)" \
 && echo "ttyd smoke test: served a request on 127.0.0.1:7699"
RUN command -v vim && command -v nano

# uid 1000 (`node`) already exists in the base image and is what the Deployments
# run as. $HOME is a PVC mount at runtime, so nothing here may depend on state
# under it existing at build time.
#
# The mkdir+chown is NOT redundant with the PVC mount. A bare `WORKDIR
# /home/session` creates the directory root-owned, so the image is unusable
# without a volume: asciinema's first run wants $HOME/.config and dies with
# `PermissionError: '/home/session/.config'`. In the pod fsGroup hides that, but
# it also meant `docker run <image> asciinema --version` — the verify step in
# build.sh — could never pass, so the verify was being skipped by hand.
RUN mkdir -p /home/session && chown 1000:1000 /home/session
USER 1000:1000
ENV HOME=/home/session
WORKDIR /home/session

LABEL org.opencontainers.image.title="agent-shell" \
      org.opencontainers.image.description="ttyd + tmux + asciinema shell for the in-cluster agent terminals" \
      org.opencontainers.image.source="https://github.com/example-owner/InfraWeaver-infra"
