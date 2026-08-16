# Mailing addon — design

**Status:** proposed 2026-08-16. Nothing built, nothing deployed, no DNS record, secret or cluster object created or changed while writing this.
**Inputs:** `2026-08-16-mailing-addon-research.md` (engine), `2026-08-16-mailing-dns-research.md` (DNS), `2026-08-16-mailing-codebase-discovery.md` (console/connector). Where this document contradicts one of them, it says so and gives the evidence.

**Operator's requirement, verbatim:** *"a new addon called mailing and use stalwart or whatever. i want it super secure, as closed off as possible also dns wise if i add a domain to the mailing it will set all the correct mailing infromation dns wise. it should also be fully integratable with wordpress sites and their mailing. you may test with infraweaver.net and .cloud… fully test it, make all features and security settings and stuff availible via the web addon page ect. do all best practises making it secure and reliable."*

---

## Design in one page

**Stalwart receives; a rented relay sends; the console addon is the only thing that ever writes DNS, and it writes in evidence-gated phases against a ledger it owns.**

- **Engine: Stalwart, and Q1 is answered YES.** The engine research's blocking unknown — "no documented REST for creating domains, accounts or DKIM keys, and if the answer is *nothing* then choose Mailu" — is wrong on current docs. Stalwart exposes a JMAP-shaped management API under capability `urn:stalwart:jmap` with `Domain/get|set|query`, `Principal/…`, `DkimSignature/…`, `Queue`, `Quota`, fine-grained permissions (`sysDomainCreate`, `sysActionCreate`, `actionReloadTlsCertificates`), and a first-class automation CLI: `stalwart-cli create domain|account/user|dkimsignature|apikey` with `--field/--json/--file/--stdin`. Mailu's trigger condition never fires. §2 gives the evidence and what would flip it back.
- **Stalwart's automatic DNS management is switched OFF, deliberately.** `Domain.dnsManagement` is a **required** field with values `Manual` / `Automatic`. We set `Manual` on every domain, forever. Automatic mode "publishes the full record set… the first time the domain is created and keeps it in sync" — MX, SPF, DKIM, DMARC, MTA-STS, TLS-RPT, SRV, autoconfig, **CAA and TLSA** — all at once, unordered, undiffed, from a Cloudflare credential living inside a PVC. That is every failure the DNS research documents, shipped as a feature. **But** the Domain object also exposes `dnsZoneFile` — server-set, read-only, "current DNS zone data for the domain". So Stalwart remains the *intent source* (we never hand-compute a mail record set) and the addon is the *only actuator*. One writer per zone.
- **Inbound self-hosted, outbound relayed — and egress :25 to the world is not in the allow-list at all.** Nothing in this design dials port 25 outward: bounces, retries and site mail all leave through the authenticated smarthost on 465. That is not a limitation dressed as a feature — it is the strongest anti-abuse control available here. A compromised mailbox can only spam through a credential we can revoke in one call and a provider that rate-limits and bills us.
- **Exactly two ports face the internet: 25 and 465.** No 993, no 143, no 110/995, no 587, no 4190, no Stalwart-served 443. The web admin sits behind Traefik + Authentik forward-auth; the MTA-STS policy is a static file served by Traefik + cert-manager; the management listener never leaves the pod.
- **"All the correct mail DNS" is a question, not an answer.** Enrolment asks intent first: **mail domain** (9 phases, evidence-gated) or **never-mail domain** (null-MX + `v=spf1 -all` + `p=reject; sp=reject` + `*._domainkey` revocation — one transaction, no ordering hazard). A domain with no MX and no mailbox intent defaults to never-mail.
- **Every gate is evidence-gated, and every gate has an audited override.** `p=quarantine` requires `dkim=pass` *proven from `rua` data*, not published. MTA-STS `enforce` requires a clean TLS-RPT cycle in `testing`. Zero reports renders **Unknown**, never "no failures". And because this repo has already been bitten by three preflight guards that could never pass — "a preflight that can never pass is one the operator turns off" — every gate has an explicit, named, reason-carrying override that is recorded in the ledger and displayed on the domain forever as *advanced without evidence*.
- **DKIM private keys are escrowed before their DNS record is published.** No escrow ⇒ no publish, the same shape as "no undo snapshot ⇒ no merge" in the accepted staging design.
- **WordPress integration is wiring, not a subsystem.** One new `IWSL_Mail_Method` class in the connector's registry, two signed methods that already exist connector-side and the console has never called (`email.methods.get`, `email.method.set`), and one new read-only signed method for the 590-line Deliverability Doctor. The Doctor's verdict *is* the acceptance test.

What the operator sees: `/mailing` lists every enrolled domain with a phase, a three-state verification badge, and the date of the last real evidence. Adding a domain opens a plan — every record classified keep / merge / replace / refuse, every refusal in a sentence — and an Apply button that only advances one phase.

---

## 1. Inventory verdict — reuse map

| Existing piece | Verdict | Why |
|---|---|---|
| **Stalwart's `dnsZoneFile` + `dnsManagement: Manual`** | **Reuse as the intent source; never as the writer.** | Removes the entire "hand-roll the mail record set" risk class while keeping a single, auditable actuator. |
| **`stalwart-cli` / JMAP management API** | **Reuse as the whole provisioning path.** `create domain`, `create account/user`, `create dkimsignature`, `create apikey`, `create Action --field @type=ReloadTlsCertificates`. Driven over ClusterIP with a scoped API-key principal. | Documented for automation; fine-grained permissions mean the console never holds the admin password. |
| **Catalog pattern** (`kubernetes/catalog/<app>/{catalog.yaml,manifests/}` → `platform.yaml` → `sync-catalog.sh` → ArgoCD) | **Reuse verbatim**, shaped like `vaultwarden`. Plain manifests, **no third-party Helm chart** — all six community Stalwart charts report `official: false`. | ⚠️ Verify after the first sync that the ArgoCD app actually manages resources: eight apps here managed zero because `directory.recurse` was missing. |
| **`secrets:` block in `catalog.yaml` + `seed-catalog-secrets.sh` + ESO** | **Reuse.** ⚠️ Declaring the key is what makes it exist; under `deletionPolicy: Retain` one missing property aborts the **entire** Secret. DKIM escrow therefore uses ESO `dataFrom` (extract-all), not enumerated properties, so adding a domain never edits a property list. | |
| **cert-manager `letsencrypt-dns` (DNS-01)** | **Reuse** for the SMTP/submission certs and for every `mta-sts.<domain>` host. Use the **staging** issuer while iterating — LE limits are per-domain-per-week. | Stalwart's own ACME client is refused: a second ACME client on the same domains for a solved problem. |
| **Dedicated `LoadBalancer` Service, `externalTrafficPolicy: Local`** | **Reuse the pattern the Traefik LB already sets.** One VIP from `vlan3-pool`'s ~8 free. | Source-IP fidelity is the input to every anti-abuse decision Stalwart makes. See §10 for why Traefik TCP is rejected. |
| **Kyverno default-deny CNP + an additive allow-list CNP** | **Reuse.** Do **not** add `mailing` to the Kyverno exclude list. The allow-list CNP is one reviewable file — and it is rendered on the addon's Security page, because it *is* the "as closed off as possible" artefact. | |
| **`longhorn-retain` with replicas constrained `zone NotIn [hypatia]`** | **Reuse.** Registered in `scripts/fleet-topology.yaml` so a stale rule fails CI. | `local-path` is refused: it welds the pod to one node and strands the PVC invisibly to every Longhorn check. Never `zone In [proxmox]` — cp3 is its own zone. |
| **Velero + Longhorn snapshots** | Reuse; add a `mailing` schedule. | Volume-level is backup track 1 of three (§4.4). |
| **Console addon SDK** (`addon.manifest.ts`, generated registry/permissions/nav/roles) | **Reuse**, with `wordpress-manager` as the reference and `wiki` as the small-surface contrast. | |
| **`withRoute(perm, handler, { scope })` + the parking rule** | **Reuse — and this is load-bearing.** See §8.1: the census has *zero* slack and the manifest `api[]` path costs budget the estate does not have. | |
| **`api/email-handlers.ts` handler shape** | **Copy structurally**: per-verb permission map, same-origin CSRF failing closed, per-verb rate limit, typed error funnel, redacted audit line. | |
| **The signed site channel** (`lib/rpc/registry.ts`, `iwsl-managed-ops.ts`, `iwsl-link-store.ts`) | **Reuse; do not invent a second site transport.** | The site never dials the console. That invariant holds. |
| **`IWSL_Mail_Registry::all()`** | **Reuse — one line.** Adding a provider is one class + one registration; the picker, wizards, validator, signed snapshot and send path all read from it. | |
| **`IWSL_Deliverability` (the Doctor)** | **Reuse the verdicts; add a signed method, no new logic.** UNKNOWN-is-not-pass already matches the console's S8 canon. | |
| **`lib/dns.ts` delete allowlist** (`explainUndeletableRecordShape`) | **Reuse unchanged and do not weaken it.** The mailing addon is the first component that legitimately writes those shapes; it gets a separate, narrow, ledger-backed write path. | It exists because a type-blind teardown once deleted a root domain's MX and SPF. |
| **Update staged runner** (plan → preview → gated waves, run state in a ConfigMap) | **Reuse** for Stalwart version upgrades. | Twelve releases in twelve weeks; pin-and-forget accumulates CVEs, auto-update runs a schema migration on a mail store at 03:00. |
| **`email_delivery` entitlement** | **Ride it.** No new site entitlement. | `ENTITLEMENT_FLAGS` is at its 32 cap; a 33rd freezes entitlements fleet-wide until every connector ships a raised `MAX_FLAGS`. |

Nothing is invented at the mechanism level. The genuinely new code is: the DNS phase engine + ownership ledger, the Stalwart provisioning client, the DKIM escrow, six console pages, one connector mail method, one connector signed method, three console RPC bindings.

---

## 2. Engine — Stalwart stays, and here is what changed

The engine research named one blocking condition: *"If the design phase discovers that domain/account/DKIM provisioning has no scriptable interface at all — no REST, no usable CLI — then the console addon degrades to a link to Stalwart's own web admin… and Mailu becomes the better choice."* That condition is false on current documentation.

| Claim | Evidence |
|---|---|
| A management API exists for the objects we need | JMAP-shaped, capability `urn:stalwart:jmap` in the request `using` array; `Domain`, `Principal`, `DkimSignature`, `Queue`, `Quota`, `BlobStore` each expose `get` / `set` / `query`; `Foo/set` is atomic create/update/destroy in one call |
| It is permissioned finely enough to avoid an admin credential | named permissions incl. `sysDomainCreate`, `sysActionCreate`, `actionReloadTlsCertificates`, `authenticate`; `stalwart-cli create apikey` mints a scoped credential attached to the authenticating principal |
| There is an automation-shaped client | `stalwart-cli create domain --field name=… --field isEnabled=true`, `create account/user --field name=… --field domainId=…`, `create dkimsignature --field domainId=… --field '@type=Dkim1Ed25519Sha256'`; four mutually-exclusive input modes including `--json` and `--stdin` |
| DNS can be kept out of Stalwart's hands without losing the record set | `Domain.dnsManagement` is required, `Manual` is a first-class value; `dnsZoneFile` is a server-set read-only field holding the domain's current DNS zone data; `publishRecords` and `dnsServerId` apply only in `Automatic` |
| DKIM private keys are portable | `DkimSignature.privateKey` is a PEM field that may be supplied directly **or read from an environment variable or a file** — so a key can be escrowed and re-`set` verbatim |
| Cert rotation does not need a pod restart | `create Action --field @type=ReloadTlsCertificates`, gated on `actionReloadTlsCertificates` — this resolves the research's open Q9 |

**Where the engine research was right and this design keeps its answer:** single-replica StatefulSet on RocksDB; `volumeClaimTemplates` (a shared RocksDB volume corrupts); bind high ports in-container (2525/4465) because `require-drop-all-capabilities` removes `cap_net_bind_service` from the permitted set and the file capability then does nothing; probe `/healthz/live` and `/healthz/ready` on the pod-bound management listener; pin `v0.16.x` by digest (`disallow-latest-tag`); community edition is **single-tenant, unlimited domains**.

**What would flip the answer back to Mailu:** an empirical finding in build step 4 that `dnsManagement: Manual` still writes DNS, that `dnsZoneFile` is empty or unparseable in Manual mode, or that `DkimSignature/get` refuses to return `privateKey` (which would make escrow impossible and reduce backup track 3 to a hope). Step 4 runs in a scratch namespace with nothing pointed at it precisely so that finding is cheap.

**The honest cost of choosing Stalwart, restated so it is not lost:** a young single-vendor codebase, ~weekly releases, and configuration that lives in a data store rather than in git. §4.3 says exactly what is in git and what is not, and §4.4 says how the not-in-git half is recovered.

---

## 3. What each half can promise

### 3.1 Inbound — self-hosted

```
internet :25 ─► MX mail.<domain>  [A record, DNS-only, grey cloud]
             ─► 203.0.113.10 :25
             ─► MetalLB VIP (vlan3-pool) :25   Service externalTrafficPolicy: Local
             ─► Stalwart :2525
```

**Promises:** it receives. Reputation gates sending, not receiving. SPF/DKIM/DMARC/ARC verification, greylisting, DNSBL, reputation, ASN/GeoIP, per-IP connection and recipient caps, auto-ban — all built in, all community edition.

**Does not promise:** availability across a home-line outage. Senders retry for ~4–5 days, so hours are invisible and a week is lost mail. A secondary MX is deliberately **not** built (§10): a secondary that cannot spool is worse than none.

**Blocking precondition, unresolved:** *is inbound :25 actually reachable from the internet today?* The engine research measured **egress** only. Until an external host proves inbound reachability, **no MX may be published** — this is build step 5's first gate, not an afterthought.

**Unavoidable disclosure, stated on the page rather than discovered:** the MX host's A record cannot be Cloudflare-proxied (Cloudflare rewrites an MX pointing at a proxied hostname with a `_dc-mx` prefix; arbitrary-TCP proxying is Enterprise Spectrum). The real IP is public. That is the one hole in "as closed off as possible" and the addon says so in words on the domain page.

### 3.2 Outbound — relayed, always

```
Stalwart ─► smarthost :465 (authenticated, credential from OpenBao) ─► provider ─► recipient
         └─ DKIM signed by us, with the domain's own key
```

**Promises:** DMARC alignment and portability are ours (our key, our selector), transport reputation is rented, and switching relays later is an SPF edit rather than a migration.

**Refuses:** direct MTA-to-MTA outbound from `203.0.113.10`, for any domain, permanently. PTR `84-82-69-110.fixed.kpn.net` cannot be changed and FCrDNS can never pass. The trap is that egress :25 **is open** — the mail sends, gets a 250, and dies silently. The addon must not offer a control that makes this possible, and the CNP must not contain an egress-25-to-world rule.

**Deferred, not rejected — outbound via `talos-prod-cp4` (Hetzner, `162.55.99.90`, settable PTR).** Preconditions, all unmet: (a) Hetzner's port-25 block confirmed lifted for this account; (b) a way to pin *egress* to cp4 without pinning *storage* there (Longhorn replicas must stay off `hypatia`); (c) the `metallb_speaker: exclude` / `longhorn_scheduling: disable` drift in `sites/hypatia.yaml` resolved deliberately rather than inherited; (d) a warm-up schedule, FBL registrations, blocklist monitoring and enforced bounce suppression. Until all four exist, this is a v2 with an owner, not a v1 option.

---

## 4. Deployment shape

### 4.1 Ports

| Port | Where it is bound | Public? |
|---|---|---|
| 25 (container 2525) | LoadBalancer VIP | **yes — unavoidable** |
| 465 (container 4465) | LoadBalancer VIP | **yes** — submission for external WordPress sites; in-cluster sites use the ClusterIP |
| 443 / JMAP / web admin | ClusterIP → Traefik → **Authentik forward-auth** | no direct exposure |
| management / `/healthz/*` | pod IP only | **never** |
| 993, 143, 110, 995, 587, 4190 | **not enabled** | no |

Two internet-facing mail ports. That number is a first-class fact on the Security page, next to the closed list.

### 4.2 Network policy

The Kyverno `generate-default-deny-cnp` ClusterPolicy (`synchronize: true`) will create `auto-default-deny` in the new namespace. Leave it. Ship one additive CNP allowing exactly:

- **ingress** `fromEntities: [world]` → 2525, 4465 only; plus traefik → the admin/JMAP port; plus Prometheus → metrics.
- **egress** → 53 (kube-dns) and 53 to public resolvers for MX/SPF/DKIM/DNSBL/MTA-STS lookups; 443 (MTA-STS policy fetch, DNSBL-over-HTTPS, ACME if ever needed); **465 to the relay endpoint only**.
- **no egress 25.** Anywhere.

### 4.3 What is in git, and what is not — stated plainly

**In git** (`kubernetes/catalog/mailing/`): `catalog.yaml` with the `secrets:` declarations, the StatefulSet (digest-pinned), the LoadBalancer and ClusterIP Services, the PVC template on `longhorn-retain` with the zone anti-affinity, the allow-list CNP, the ExternalSecrets, the cert-manager Certificates, the `mta-sts-policy` static-file Deployment, the Velero schedule, the ServiceMonitor and alert rules, and the seed `config.json` that Stalwart reads at first boot.

**Not in git — and this is the honest half.** Domains, principals, app passwords, DKIM signature objects, ACLs, Sieve scripts, blocked-IP lists, per-account quotas and every message live in RocksDB inside the PVC. `git diff` cannot see them and ArgoCD does not reconcile them. This repo has already paid for pretending otherwise. Three consequences, each designed for:

1. **The addon's ledger is the git-visible shadow of the mail-object state.** Which domains are enrolled, at which phase, with which selector, against which zone — all in a ConfigMap the addon owns (§5.3), enumerable and diffable.
2. **DKIM private keys are escrowed out of the PVC on creation** (§4.4).
3. **Provisioning is scripted, never clicked.** Anything created through Stalwart's web admin is invisible to the addon and will be reported as drift.

### 4.4 Backup and restore — three tracks, and the drill is the deliverable

| Track | Mechanism | Covers | Gap |
|---|---|---|---|
| 1. Volume | Longhorn snapshot + Velero `mailing` schedule | everything, including config and messages | crash-consistent only; RocksDB recovery under an unclean snapshot is **unverified** — build step 4 hard-kills the pod mid-write and restores, and if RocksDB does not survive it, track 1 is not a backup |
| 2. Per-account logical | Vandelay (JMAP export to a SQLite archive per account) | mailboxes, messages, Sieve, identities; portable off Stalwart entirely | **explicitly excludes** server config, ACLs, DKIM keys and account provisioning; one archive per account |
| 3. Configuration + keys | the addon: `Domain/query` + `DkimSignature/get` → OpenBao (`platform/mailing-dkim`, ESO `dataFrom`) + the ledger ConfigMap | domain list, selectors, **DKIM private keys**, phase state, record ownership | written by the addon on every provisioning event, verified by read-back |

**The DKIM escrow gate.** On creating a domain the addon: (1) creates the Domain with `dnsManagement: Manual`, `dkimManagement: Automatic`; (2) reads the generated `DkimSignature.privateKey`; (3) writes it to OpenBao read-merge-CAS (KV v2 replaces the whole object on write — the alert manager's `contact-secrets.ts` is the precedent, and the console's OpenBao policy grants no wildcard, so a new path is an infra-repo change); (4) **re-reads it back and compares**; (5) only then is the DKIM DNS record eligible for publication. **No verified escrow ⇒ no publish.** Losing a DKIM private key is not recoverable by rotating: archived signatures break and every receiver cache holding the selector sees a mismatch during the gap.

Restore is `DkimSignature/set` with the escrowed PEM — the same API, exercised in step 4, not first attempted during an incident.

---

## 5. The domain lifecycle

### 5.1 Enrolment asks intent first

```
add domain → resolve zone (explicit zoneId, assert apex == domain)
           → read-only inventory of every existing record
           → classify: none / mail-shaped / hand-set-and-foreign
           → ASK: mail domain, or never-mail domain?
```

**Never-mail** — the genuinely most-closed configuration, and the default for a domain with no MX and no mailbox intent. One transaction, no ordering hazard:

```
<domain>                  MX    0 .
<domain>                  TXT   "v=spf1 -all"
_dmarc.<domain>           TXT   "v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s; rua=mailto:dmarc-rua@<collector>"
*._domainkey.<domain>     TXT   "v=DKIM1; p="
```

Null MX suppresses the implicit-MX fallback to the apex A — which is the live bug on `infraweaver.cloud` today, where the world tries to deliver mail to a Cloudflare proxy IP. Because a never-mail domain has no mailbox, `rua` **must** be off-domain, which means the addon must publish `<domain>._report._dmarc.<collector>  TXT "v=DMARC1"` on the collector's zone first. **It refuses the whole never-mail set if it cannot** — otherwise no reports arrive and the console reports "DMARC configured" over silence.

**Mail domain** — nine phases, §5.2. Note the corollary: a mail domain hosts its own `dmarc@<domain>` mailbox, so `rua` is same-domain and the external-destination authorization record is not needed at all.

### 5.2 The phases, and what each one refuses

| # | Writes | Advances only when | Refuses |
|---|---|---|---|
| 0 | none | — | proceeding at all if the zone holds an SPF or DMARC the addon did not create and the operator has not approved the specific diff |
| 1 | none | intent chosen | — |
| 2 | MX | every target resolves to A/AAAA, no target is a CNAME, `proxied=false` asserted, and the record resolves through **two independent DoH providers** | publishing MX before external inbound :25 reachability is proven |
| 3 | DMARC `p=none` + `rua`; TLS-RPT | both resolve | advancing if `rua` is off-domain without the `_report._dmarc` authorization record |
| 4 | SPF `~all`; DKIM selector(s) | records resolve; DKIM status explicitly **unproven** | a second `v=spf1` at the apex (ever); >10 recursive lookups or >2 void lookups; `+all`; `a`/`mx` while the apex A is Cloudflare-proxied; publishing a DKIM selector whose private key is not escrow-verified |
| 5 | **none** | see the numeric gate below | claiming anything. This is the gate the design hangs on |
| 6 | SPF `~all` → `-all` | every source in `rua` enumerated and dispositioned; one more clean cycle | — |
| 7 | `p=quarantine pct=25` → `pct=100` → `p=reject; sp=reject` | a clean aggregate cycle at each step | skipping `quarantine`. Quarantine is recoverable by the recipient; reject is not |
| 8 | `mta-sts` host + policy (`testing`, `max_age: 86400`), then `_mta-sts` TXT, then `enforce`, then lengthen | the HTTPS endpoint returns a valid policy over a valid cert **and** its `mx:` patterns cover every live MX | publishing the TXT before the endpoint validates; `enforce` before a clean TLS-RPT cycle; deleting the records without first publishing `mode: none` and waiting out `max_age` |
| 9 | CAA | every CA in every issuance path is enumerated | publishing CAA before Cloudflare Universal SSL's CA set is known — see §12 |
| — | TLSA / DANE | **never** | §10 |

**Phase 5's numeric gate.** From `rua` data, all four: ≥100 messages observed, from ≥3 distinct report-generating receivers, spanning ≥7 calendar days with ≥5 days carrying at least one report; DKIM pass ≥99% from every source the operator marked authorized; SPF-aligned pass ≥95% from those sources (the 5% is forwarding, which DKIM covers); zero un-dispositioned sources. **Zero reports refuses and renders Unknown** — "no failures observed" and "no data" must never render the same way.

**The override.** A low-volume domain may never reach 100 messages. `mailing:admin` may advance a phase without its evidence by supplying a written reason; the ledger records who, when and why, and the domain carries an *advanced without evidence* badge for the rest of its life. This exists because a gate that can never pass is a gate the operator disables, and this repo has three of those in its recent history.

### 5.3 Ownership, idempotency and drift

**The ledger** is a ConfigMap in the console namespace with optimistic concurrency, shaped like `infraweaver-iwsl-sites`: `(zoneId, name, type, contentHash, cloudflareRecordId, phase, writtenAt, writtenBy)`. Cloudflare carries no ownership metadata, so ownership must be ours.

**Every write is read-diff-write, never blind.** The Cloudflare DNS API has **no idempotency key** — a retried `POST` after a timeout-that-succeeded creates a duplicate, and two `v=spf1` records is a permanent permerror. Classify each record as absent → `POST`; wrong → `PATCH` the existing id (**never** delete-then-create for a policy record — the gap is a window with no SPF or DMARC at all); duplicated → **surface and refuse to choose**; correct → write nothing.

**Never retry a write because a read failed.** The SOA minimum on all three zones is 1800s, so anything that queried a name before it existed — including the addon's own preflight — sees NXDOMAIN for up to 30 minutes afterwards. Preflight existence checks therefore use the Cloudflare API (no cache); verification uses DoH; the two are never confused.

**Existence is decided on content, not rcode.** `infraweaver.cloud` has a proxied wildcard, so *every* name returns NOERROR; `infraweaver.net` is empty, so every name returns NXDOMAIN. A verifier keying on rcode reports `.cloud` fully configured and `.net` fully broken, both wrongly. NODATA is absent.

**Drift detection is read-only and scheduled; writes only ever happen on operator action.** Continuous reconciliation of *policy* records would silently revert a deliberate hand edit — precisely the "control that could not work while reporting success" shape this codebase has been bitten by. Drift is a finding with a one-click re-apply that goes through the same plan → preview → confirm.

### 5.4 The Cloudflare credential

A **new, separate, zone-scoped token** at a new OpenBao path (`platform/mailing-dns#cf-token`), with `Zone → DNS → Edit` + `Zone → Zone → Read`, restricted to the enrolled zones only. **The token's zone list is the enrolment boundary** — a domain outside it cannot be touched at all, structurally.

Today one account-wide token is shared byte-identically between ExternalDNS, cert-manager and the console, and sees all 7 zones including three client sites. The mailing addon would be the fourth consumer and the first deliberate mail-record writer. It does not join that pool.

**`CF_ZONE_ID` must be structurally unreachable from this addon.** Its live value resolves to `example.com` — the operator's real production mail domain and the platform's SSO/alerting sender. Any code path omitting an explicit `zoneId` writes there. The addon's Cloudflare wrapper takes `zoneId` as a required argument, and asserts `resolveZoneApex(zoneId) === domain` before every write. A unit test pins that the env fallback cannot be reached.

### 5.5 The three test domains map to three different flows

| Domain | Flow | What it proves |
|---|---|---|
| `infraweaver.net` (empty zone, 0 records) | full mail domain, phases 0–9; becomes the report collector | the happy path, slowly, on real evidence |
| `infraweaver.cloud` (proxied wildcard, Hostnet SPF, `p=reject`, no MX, no `rua`) | **migration** — the addon writes **exactly one record**: `rua` PATCHed onto the existing DMARC. Everything else is a *finding*, proposed and refused | that the addon's most valuable action on a live domain can be adding one telemetry record and declining the rest. It must not touch the Hostnet SPF, which is a real deliberate third-party authorization |
| a domain the operator nominates (candidate: `infraweaver.nl`, present in the account, unmeasured) | never-mail set, one transaction | the closed-off path, after a read-only inventory confirms it is web-only |

`example.com` is out of scope and the addon must refuse to enrol it in v1.

---

## 6. Security model

### 6.1 Permissions

| Permission | Operations |
|---|---|
| `mailing:read` | list domains/mailboxes, read posture and verdicts, redacted delivery log, queue depth, the rendered CNP and open-port facts, read a computed DNS plan |
| `mailing:write` | send a test message, pause/resume/retry the queue, edit non-credential routing, **generate** a DNS plan, advance a phase whose gate has already passed on evidence |
| `mailing:admin` | create/delete a domain or mailbox, mint or rotate an app password or the relay credential, **apply** a DNS write, override an evidence gate, set never-mail mode, delete a delivery log |
| `mailing:client` | one tenant reading its own domain's posture and delivery report — accepted by exactly the tenant-report routes and by nothing else, so the bound is structural, copying `wordpress:client` |

Namespace is clean: `mailing` is not in `ALL_PERMISSIONS`, so `/mailing` is not a reserved route prefix. No permission may be in the escalation tier (`GROUP_DENIED_PERMISSIONS`); note `alerts:admin` is deny-listed for exactly the reason a mail admin tier is dangerous — it confers every SMTP password the deliverer can reach.

Per-domain scoping mirrors `wordpress-rbac.ts`: `mailingScope(domain) → /mailing/domains/<domain>`, `MAILING_ALL_DOMAINS_SCOPES = { "/", "/mailing", "/mailing/domains" }`, and the enumerator must check the assignment's **role shape**, not just its scope — a Jellyfin role parked at a mailing scope previously enumerated a WordPress site.

### 6.2 Feature gates — `PLATFORM_ENABLE_ALL=1` is live

Any new gate is **ON at the next image roll** unless it is in `NEVER_DEFAULTED`. Three go in, applying the stated criterion (*takes unattended destructive action, writes credentials, or hands out authority*):

| Gate | Class precedent |
|---|---|
| `MAILING_DNS_WRITE_ENABLED` | `FLEET_PROVISION_ENABLED` — mutates infrastructure outside the cluster |
| `MAILING_PROVISION_ENABLED` | `SECRET_REMEDIATION_WRITE_ENABLED` — mints and stores credentials |
| `MAILING_OUTBOUND_ENABLED` | `WORDPRESS_PATCH_AUTO_REMEDIATION_ENABLED` — arms real sending as customer domains |

`MAILING_ENABLED` (the read-only posture surface) rides the master switch, deliberately, so the surface is not dark on arrival. Each gate's `accepts` vocabulary is stated in the manifest comment — on a `LITERAL_TRUE_ONLY` gate, `=1` silently does nothing, and the production Deployment already records that.

No new *entitlement* flag: `ENTITLEMENT_FLAGS` is exactly at `MAX_ENTITLEMENT_FLAGS = 32` and a 33rd is rejected wholesale by every connector still on the 32 cap, freezing entitlements fleet-wide.

### 6.3 Credentials

| Secret | OpenBao path | Held by |
|---|---|---|
| Stalwart local admin (break-glass) | `platform/mailing#admin-password` | bootstrap only |
| Console API key (scoped principal) | `platform/mailing#console-api-key` | the addon; only the permissions it drives |
| Relay submission credential | `platform/mailing#relay-password` | Stalwart, via ESO |
| Per-domain DKIM private keys | `platform/mailing-dkim` (ESO `dataFrom`) | escrow / restore only |
| Zone-scoped Cloudflare token | `platform/mailing-dns#cf-token` | the addon |

**The admin identity is directory-independent.** This platform has twice had an Authentik restore leave join tables empty — group-conferred superuser died and OIDC tokens carried no `email`/`groups` while every dashboard read healthy. A mail server whose admin authority depends on Authentik groups inherits that. OIDC is for the web admin *convenience* path; the local admin in OpenBao is the break-glass one.

**Admin accounts are never mail accounts**, and no credential ever lands in git.

### 6.4 Isolation, honestly

Community edition is **single-tenant with unlimited domains**. Per-tenant quotas and isolation are Enterprise. So v1 promises: separate mailboxes, separate app passwords, separate DKIM keys, separate per-principal quotas, one server, one admin plane. It does **not** promise sealed compartments per agency client. If that becomes the product story it is a licence purchase, not a configuration, and it changes the data model — so it is decided now, as No.

### 6.5 Rate limits and open-relay prevention

Four layers, the last of which only exists because of the relay decision:

1. **Inbound per-remote-IP** — connections/hour, messages/connection, recipients/message.
2. **Outbound per-principal** — the containment boundary when a WordPress site is compromised. A site that suddenly sends 10,000 messages is throttled and alerted, not discovered from a blocklist entry. **This is not optional**: once a site's `wp_mail` runs through InfraWeaver Mail, its newsletter volume runs through our quota and our reputation. The mailbox page shows the site's subscriber count next to its quota so a 5,000-recipient campaign is visibly going to hit the ceiling before it does.
3. **Auth-failure auto-ban** — brute force, enumeration, scanning, SYN floods, all built in. ⚠️ Verify against v0.16 whether BlockedIp/AllowedIp changes take effect on live connections without a restart; a console "Block this IP" button that silently does nothing until the next pod restart is worse than no button. If it does not, the button is not shipped.
4. **The relay is a hard ceiling** — because there is no egress :25, the worst case is bounded by a credential we revoke in one call.

**Open-relay assertion.** A scheduled in-cluster probe attempts to relay a message for an unrelated domain through :25 and through :465 without auth, and **asserts rejection**. The result and its timestamp are a first-class fact on the Security page. Honest scope: this proves the *server's policy*, not the internet path — an external relay test needs an outside host, and until one exists that tier reads **Unverified**, not green. Given this repo's history of controls that report success while doing nothing, that distinction is the whole point.

---

## 7. WordPress integration

**What a site gets:** a principal `<site-id>@<sending-domain>`, an app password minted by the addon and never typed by a human, a per-principal outbound quota, and DKIM alignment on its own domain.

**Reused surface:**

- `IWSL_Mail_Registry::all()` — **one new class**, `IWSL_Mail_Method_Infraweaver`, fields `host` / `port 465` / `username` / `app password`, ordered ahead of plain `smtp`. One line in `all()`. No new endpoints, no new nonces, no switch statements — that is the registry's stated contract.
- **`email.methods.get` and `email.method.set` already exist connector-side and the console has never called them.** The read is secret-free by construction (`snapshot()` replaces every credential with a boolean); the write accepts a credential one way only, inside the signed envelope, and never echoes it. Console work: an `RpcMethod` union entry, `RpcParams`/`RpcResults`, an `RPC_REGISTRY` validator **mirroring the plugin's own rules** (so the console refuses to sign what the plugin would refuse to execute — a malformed push burns a sequence number on the far side), and two wrappers on `emailReadTransport` / `emailWriteTransport`.
- **The Deliverability Doctor is the acceptance test.** It already answers "is the transport that is actually configured authorised by the SPF record that actually exists", reports UNKNOWN rather than pass, and takes the weakest link rather than an average.

**One new signed method:** `deliverability.get`, read-only, riding the existing `email_delivery` entitlement the Doctor already gates on. That is the only connector protocol change v1 needs.

**The anti-phishing bound:** the addon refuses to configure a site whose sending domain is not enrolled and DKIM-proven, and the `From:` allow-list is bound to that domain. A console that can send as a customer's domain is a phishing tool if the RBAC is wrong; this makes the bound structural rather than procedural.

**Home in the UI:** extend the existing email panel inside `/wordpress/<site>/manage` — zero new routes, zero nav cost, and the panel already merges a connector-first read with a `wp option pluck` fallback that doubles as third-party-SMTP conflict detection. The console's three static presets (`office365`/`google`/`custom`) are retired in favour of `email.methods.get`; an un-enrolled or offline site renders **Unknown**, not empty.

**Not built:** console-driven newsletter campaigns (§10).

---

## 8. The console surface

### 8.1 The gates, and the two decisions they force

**Route-scope census: 479 of 479, zero slack.** A thin WordPress-style delegator classifies as `raw` (untriaged); the *generated addon API shim* classifies as `wrapper` (also untriaged — 2 of the wiki's 3). So:

> **Decision: `mailing` uses the parking rule, not the manifest `api[]` path.** A concrete `src/app/api/mailing/` directory suppresses the generated shim. Each route module is written as `export const POST = withRoute(permission, handler, { scope: mailingScopeFrom(...) })` — the `withRoute` call in the module's own source, so `check-route-exports.mjs` rule 3 passes and the census classifies it as **`scoped`**, which costs zero budget. Do not raise the baseline; the file forbids it in four places.

**`nav-ia`: 47 rows / 31 visible / rail+topbar = 59.** One `navItems` entry breaks both assertions.

> **Decision: take the row** (→ 48 / 32 / 60), with a written reason following the wiki-row precedent. Mailing spans domains, not sites; burying "which of my domains can actually deliver" inside per-site chrome makes the one question the addon exists to answer unfindable. `MAX_CORE_NAV_ROWS = 57` is unaffected — addon rows are deliberately not counted there. `MAX_DASHBOARD_ROUTES` excludes `(addon-pages)`, so the pages cost nothing.

**Route size** is nearly free — an addon page shim is 189 bytes because the real components arrive as lazy chunks. The thing that would bite is a static import growing the `(dashboard)` layout or `rootMainFiles`; don't.

**Design ratchets** (all six scan `src/addons/**`): zero raw hex, `IconButton` for icon-only buttons, `aria-hidden` or the shared `StatusDot` on every dot, token z-rungs only, no `text-[Npx]`, `HoldToConfirm` as the *only* confirmation mechanism — hand-rolled "type the domain name" gates are detected by three separate shapes, one of which was added *because* an `src/addons` file evaded a per-directory scan.

**S8 is mandatory here more than anywhere:** "no DMARC reports yet" must never render like "no failures".

### 8.2 Pages

| Path | Permission | Contents |
|---|---|---|
| `/mailing` | `mailing:read` | fleet posture: every enrolled domain, phase, three-state badge, date of last real evidence |
| `/mailing/domains/[domain]` | `mailing:read` | intent, the record table with per-record Tier A/B/C status, the phase ladder showing what each gate still needs, the ownership ledger, the findings the addon refuses to fix |
| `/mailing/domains/[domain]/plan` | `mailing:read` view / `mailing:admin` apply | the diff: keep / merge / replace / refuse, each with a sentence. One phase per Apply |
| `/mailing/mailboxes` | `mailing:read` / `mailing:admin` | principals, quotas, app passwords (minted once, shown once, revocable) |
| `/mailing/security` | `mailing:read` | the "as closed off as possible" page: the two open ports and the closed list, the rendered CNP, the open-relay probe result with timestamp, auto-ban state, rate limits, cert expiry, **and the plain statement that the MX host's A record exposes the real IP** |
| `/mailing/queue` | `mailing:read` / `mailing:write` | queue depth, deferred/bounced with causes, retry/flush |

Six pages, `pages/` thin shells, `components/` grouped by feature, `lib/` with `import "server-only"` where it belongs, and `api/` handlers copying `email-handlers.ts` structurally.

---

## 9. Lifecycle and failure modes

| Phase / failure | Mechanism | What the operator sees |
|---|---|---|
| Home line down | senders retry ~4–5 days | Gatus MX probe red; domain page "inbound unreachable since T". Nothing lost under ~2 days; a banner escalates past that |
| PVC node loss | `longhorn-retain`, replicas off `hypatia` | pod reschedules. If the volume faults, inbound 4xx-defers (senders retry) and the page says **receiving paused**, never "healthy" |
| Longhorn MTU/link fault on the stretched VLAN | replica placement constraint | the constraint is registered in `fleet-topology.yaml`, so a stale rule fails CI rather than failing quietly at 03:00 |
| Relay credential expired/revoked | Stalwart queues | deferred count climbs, Alertmanager fires, queue page names the cause |
| Cert renewed, not reloaded | `ReloadTlsCertificates` Action fired post-renewal | cert expiry is a first-class fact with a Gatus probe on 465; a stale cert shows as a red fact before a client notices |
| ESO / OpenBao token expiry | ExternalSecret goes stale | secret-freshness fact on the Security page. This has taken this platform down before as "ArgoCD Degraded" |
| DNS write partially applied | the ledger holds what was written | "phase N applied; phase N+1 refused because …". Never a half-state rendered green |
| Duplicate SPF/DMARC found | classifier detects `present-and-duplicated` | **the addon refuses to choose.** Both are rendered; an operator decides. It never auto-deletes a policy record |
| Zero DMARC reports | phase 5 gate | **Unknown**, with "the instrument may be broken" — not "no failures" |
| MX changed while MTA-STS is enforcing | the `mx:`-coverage invariant is re-checked on every MX change | the MX change is **blocked** with "MTA-STS policy would not cover the new host — update the policy first" |
| MTA-STS mistake | `max_age` starts at 86400 | the blast radius is a day, not a week, and retirement is `mode: none` + wait, never a delete |
| Compromised WordPress site | per-principal outbound quota | quota trips, alert names the principal and the count; containment is one app-password revocation |
| Stalwart upgrade with a schema migration | staged runner: plan → preview → gated waves, run state in a ConfigMap | a backup verified *before* the wave; a closed laptop loses nothing |
| Domain de-enrolment | ledger-backed teardown | ordering is enforced: MTA-STS retired (`mode: none`, wait `max_age`) **before** MX is removed; DKIM selectors deleted only after ≥7 days and a proven replacement. The shared `lib/dns.ts` delete allowlist is **not** weakened to make this possible |

---

## 10. Rejected alternatives

- **Stalwart's automatic DNS management** — rejected. It publishes the full set at once, unordered and undiffed, including TLSA on unsigned zones, CAA before the Universal SSL CA set is known, MTA-STS TXT before the policy endpoint is proven, and a DMARC policy with no evidence gate. It would clobber `infraweaver.cloud`'s hand-set Hostnet SPF and would place a Cloudflare credential inside a PVC as an unscoped fourth writer. `dnsManagement: Manual` + reading `dnsZoneFile` keeps the intent and drops all of it.
- **Mailu** — rejected; its trigger condition (no scriptable provisioning in Stalwart) is false (§2). Eight containers, no JMAP, and a hand-written Cloudflare reconciler would be the price.
- **Self-hosted outbound from `203.0.113.10`** — rejected permanently. FCrDNS can never pass. Egress 25 being *open* is the trap, not the opportunity.
- **Outbound via cp4/Hetzner in v1** — deferred with named preconditions (§3.2), not rejected.
- **Traefik `IngressRouteTCP` for the mail ports** — rejected. It needs PROXY protocol v2 end-to-end plus trusted-network config on every listener; get it wrong and Stalwart sees Traefik's pod IP, at which point SPF, DMARC, greylisting and per-sender rate limits all evaluate against the wrong address and auto-ban blocks Traefik. It also puts the platform's entire HTTP ingress in the blast radius of a mail-port typo. A dedicated LoadBalancer with `externalTrafficPolicy: Local` preserves source IP with no PROXY protocol at all, for the price of one VIP.
- **An egress-25-to-world rule "for report submission and internal notifications"** — rejected. It is a second sending path with the same reputation problem, for traffic the relay already carries. Its absence is a control.
- **DANE / TLSA** — rejected. DNSSEC is disabled on all three zones and an unsigned TLSA is ignored by every conforming implementation; with DNSSEC it would pin a certificate we do not control, and a stale TLSA hard-breaks inbound mail. MTA-STS is the right tool for provider-hosted MX. **The addon must not offer a TLSA button.**
- **A 33rd entitlement flag** — rejected; ride `email_delivery`.
- **The manifest `api[]` route path** — rejected; the generated shim is untriaged and the census has zero slack (§8.1).
- **Continuous DNS reconciliation** — rejected; silently reverting an operator's deliberate DMARC edit is the exact failure shape this codebase has paid for.
- **Multi-replica Stalwart on PostgreSQL + S3 + a coordination backend** — rejected for v1. A split-brain mail store loses mail, and a three-node cluster with one node 15 ms away across a WAN is a bad place to learn a new coordination protocol.
- **A secondary MX** — rejected. A secondary that cannot spool is worse than none; senders already retry for days.
- **A "configure all mail DNS" button** — there is deliberately no such control anywhere in this design. Every write is one phase with one gate.
- **Reading mailbox contents from the console** — not built (§12).
- **Console-driven newsletter campaigns** — not built in v1. The site-side suite is already correct (never-send-twice is a UNIQUE DB key, crash-resume is designed, consent evidence is schema-additive); driving it from the console needs a signed newsletter surface and a `NEVER_DEFAULTED` send gate, and the per-principal quota (§6.5) must be proven first.

---

## 11. Testing plan

**Run jest per-file with `--maxWorkers=1`; the full suite OOMs on this box. Do not run `next build` or `tsc` casually — disk is at 86% and this machine was OOM-killed today.**

1. **Unit (offline, no cluster, no network).** Record-set computation for both intents. The SPF lookup counter (≤10 terms, ≤2 void) and the `a`/`mx`-against-a-proxied-apex refusal. The two-SPF permerror refusal. **The DoH parser against a wildcard-zone fixture and an empty-zone fixture** — NODATA is absent, NXDOMAIN is absent, rcode decides nothing; this is the single test that catches the `.cloud`-vs-`.net` inversion. Ledger classification (mine / mine-drifted / foreign). The phase-gate evaluator against a zero-reports fixture, asserting Unknown ≠ pass. The zone-apex assertion, and a test pinning that the `CF_ZONE_ID` env fallback is **structurally unreachable** from the mailing write path.
2. **Scratch namespace, nothing pointed at it.** Prove `stalwart-cli create domain|account/user|dkimsignature|apikey` over ClusterIP. Prove `dnsManagement: Manual` writes no DNS (watch the zone read-only for an hour). Prove `dnsZoneFile` is readable and parseable. **DKIM escrow round-trip:** read `privateKey` → OpenBao → destroy the signature → `DkimSignature/set` with the escrowed PEM → same public key. Prove `ReloadTlsCertificates`. **Hard-kill the pod mid-write and restore from a Longhorn snapshot** — if RocksDB does not survive it, backup track 1 is not a backup and this design changes. Measure RocksDB latency on `longhorn-retain`.
3. **Open-relay assertion in-cluster, before any public exposure.** Relay attempt for an unrelated domain on :25 and unauthenticated :465 must be rejected, and the assertion must be visible and dated on the Security page.
4. **External inbound :25 reachability from an outside host.** This gates every MX publication. Five minutes, and it must happen.
5. **`infraweaver.net`, phases 0–9, deliberately slowly**, on real `rua` data. This is weeks. The gates are the feature.
6. **`infraweaver.cloud`:** assert the addon writes exactly one record and refuses the rest; assert the Hostnet SPF is untouched; assert the wildcard/MTA-STS pre-break and the SPF-`a`-on-proxied-apex weakness are reported as findings, proposed, and not applied.
7. **Never-mail set** on the operator-nominated domain, after a read-only inventory, including the `_report._dmarc` authorization record on the collector zone.
8. **WordPress on hi2 via the alpha channel:** switch a site to InfraWeaver Mail over `email.method.set`; the Deliverability Doctor's green verdict is the acceptance evidence, not a claim. Then trip the per-principal quota on purpose and confirm the alert and the containment.
9. **The restore drill is the deliverable.** A backup that has never been restored is a hypothesis.

---

## 12. Traps, YAGNI, and what I would refuse to ship

**Traps carried forward from research, each already designed for above:** the 1800s negative cache turning a failed read into a duplicate write; rcode-based existence on a wildcard zone; `CF_ZONE_ID` silently resolving to the operator's live mail domain; the shared account-wide Cloudflare token; `deletionPolicy: Retain` aborting a whole Secret for one missing property; `PLATFORM_ENABLE_ALL=1` arming any new gate at image roll; the route-scope census at exactly zero slack; the 32-flag entitlement ceiling; the `metallb_speaker: exclude` / `longhorn_scheduling: disable` drift on cp4; ArgoCD apps that manage zero resources without `directory.recurse`.

**Deliberately not built (YAGNI):** multi-tenant isolation (Enterprise licence, decided as No); IMAP/JMAP client access and the ports for it; POP3, ManageSieve, 587; mailbox-content reading from the console — that is authority over correspondence, needs its own tier, its own audit shape and its own gate, and nothing in this design needs it; console-driven newsletter campaigns; a secondary MX; multi-replica clustering; DANE; BIMI; Cloudflare Email Routing integration; a site→console network path; per-provider DKIM fetching from third-party APIs (the addon supports CNAME-shaped DKIM records for hosted providers and never "fixes" one into a TXT, but it does not go and get them).

**I would refuse to ship these without more evidence:**

1. **Any MX record** until inbound :25 reachability from the internet is measured. Everything downstream is fiction otherwise.
2. **Any CAA record** until the CA set behind Cloudflare Universal SSL for this account is enumerated. The token 403s on the SSL endpoints, but this is resolvable without a token: read the issuer from the served certificate of a proxied hostname. Until that is done, a `0 issue "letsencrypt.org"` can break the `infraweaver.cloud` website's certificate renewal — and if the failing cert is an MTA-STS policy host with `enforce` cached, that becomes an inbound-mail outage.
3. **Any DKIM DNS record** whose private key has not been escrow-verified by read-back.
4. **A "Block this IP" button** until it is confirmed that BlockedIp changes affect live connections without a pod restart on v0.16.
5. **Live-connection promises about MTA-STS certificate matching, STARTTLS offering, or MX answering** — port 25 is blocked from console pods and 53/TCP with it, so those checks cannot run. They render **Unverified**, permanently, unless a deliberate NetworkPolicy change is made. Opening console egress 25 is itself a decision with abuse implications and is not proposed here.

**Genuinely unresolved and needing a decision from outside this document:** whether Hetzner's port-25 block is lifted for this account (gates the entire v2 outbound story); whether `203.0.113.10` and `162.55.99.90` are on the Spamhaus PBL/CSS — the earlier check was refused by Spamhaus from a public resolver and the *control* returned the same refusal code, so the empty result means nothing; whether the Cloudflare API accepts a single >255-character `content` string for a 2048-bit DKIM TXT or requires pre-split character-strings (no such record exists in any of the seven zones to observe); whether Cloudflare Email Routing is enabled on any enrolled zone (the token 403s on that endpoint); and which relay provider is chosen — the properties that decide it are: does it accept our own DKIM key, does it expose bounce/complaint webhooks, does it publish a stable SPF include, and does it permit sending from many customer domains.

---

## 13. Build order — each step ships and reverts alone

1. **Read-only posture surface.** Addon skeleton, manifest, `mailing:read`, `/mailing` + `/mailing/domains/[domain]`. Reads Cloudflare with an explicit `zoneId` and verifies over two DoH providers. **No writes, no mail server, no new secrets.** Ships value on day one — it would immediately surface `infraweaver.cloud`'s `p=reject`-without-`rua`, its missing MX, and `example.com`'s missing Microsoft 365 DKIM selectors. Revert: delete the directory.
2. **Zone-scoped token + ownership ledger + plan/preview.** Still no writes — the plan is computed, classified and rendered; there is no Apply button. `MAILING_DNS_WRITE_ENABLED` lands in `NEVER_DEFAULTED`, off. Revert: delete the token, delete the ConfigMap.
3. **Never-mail mode, Apply enabled.** The first write the addon ever makes is the safest one that exists: one transaction, no ordering hazard, on an operator-nominated domain — plus the `_report._dmarc` authorization record. Revert: delete four records.
4. **Stalwart in a scratch namespace, ClusterIP only, nothing pointed at it.** Catalog entry, manifests, CNP, ESO. Prove §11.2 in full — provisioning, `Manual` DNS, DKIM escrow round-trip, cert reload, RocksDB crash-and-restore, Longhorn latency. **This is the step that can still change the engine decision, and it is cheap here.** Revert: delete the namespace.
5. **Inbound go-live on `infraweaver.net`.** External :25 reachability proven *first*; then the LoadBalancer VIP; then MX; then phases 3–7 on real report evidence over weeks. Revert: delete the MX (and only after MTA-STS retirement if step 7 has run).
6. **Outbound relay, mailboxes, app passwords, per-principal quotas, the outbound-volume alert.** `MAILING_PROVISION_ENABLED`, `MAILING_OUTBOUND_ENABLED`. Revert: revoke the relay credential.
7. **MTA-STS (phase 8).** Policy host Deployment + Certificate + IngressRoute; `testing` at `max_age: 86400`; a clean TLS-RPT cycle; `enforce`; only then lengthen. Revert: `mode: none`, wait `max_age`, then remove.
8. **WordPress binding.** Connector `deliverability.get` + the `infraweaver` mail method down the alpha channel to hi2; console RPC bindings for `email.methods.get` / `email.method.set` / `deliverability.get`; the manage-panel rework. Revert: switch the site's mail method back — the registry makes that one write.
9. **CAA (phase 9)**, after the Universal SSL CA set is read off a served certificate, with "a certificate renewal succeeded" as the verification step rather than "the record resolves".
