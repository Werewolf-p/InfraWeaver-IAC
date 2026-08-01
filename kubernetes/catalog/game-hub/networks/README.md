# game-hub / networks — generator-owned

ArgoCD serves this directory in **directory mode** (no `kustomization.yaml`, same as
`../servers`), so every `*.yaml` here is applied as-is and this README is ignored.

Its only job right now is to make the path exist in git. An ArgoCD Application
pointing at a path that does not exist goes `Unknown`/error rather than syncing an
empty set, so `catalog-game-hub-networks.yaml` would be red from the moment it is
bootstrapped until the first network is created.

## What lands here

Velocity proxy networks, authored by the console's Network Fabric reconciler
(`apps/infraweaver-console/src/addons/gamehub/lib/network/manifest.ts` and
`manifest-git.ts`). Per network, roughly:

- a `gamenet-<name>` Deployment and Service for the proxy,
- an `ExternalSecret` projecting the Velocity forwarding secret from OpenBao at
  `secret/platform/game-hub/networks/<name>`.

## Two things not to undo

**The forwarding secret never appears here.** The `ExternalSecret` carries the
remote *key path* only, which is why it is safe in git. The materialised `Secret`
is mounted into the proxy as a file (mode `0400`) and reaches members through
`valueFrom.secretKeyRef` — never an inline env value. Writing the value into a
manifest would recreate the `RCON_PASSWORD` incident, where a plaintext inline env
value was returned verbatim from a `GET` guarded at the lowest role tier.

**`/spec/replicas` on `gamenet-*` is cluster-owned**, via `ignoreDifferences` plus
`RespectIgnoreDifferences=true` on the Application. Removing either makes selfHeal
fight every scale and produces permanent OutOfSync.

The feature is gated by `GAME_HUB_NETWORKS_ENABLED` in the console and ships off by
default, so this directory is expected to be empty until it is switched on.
