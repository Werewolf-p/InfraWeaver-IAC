# Mailing addon — engine + deployment research

**Date:** 2026-08-16
**Phase:** RESEARCH ONLY. No code, no manifests, no deployment. This document exists to be argued with, then designed against.
**Requirement (operator, verbatim):** *"setup a dedicated agent or agents to first plan, discover, plan again, deaign with the design examples for making a new addon called mailing and use stalwart or whatever. i want it super secure, as closed off as possible also dns wise if i add a domain to the mailing it will set all the correct mailing infromation dns wise. it should also be fully integratable with wordpress sites and their mailing. you may test with infraweaver.net and .cloud , i think those are in my cloudflare. fully test it, make all features and security settings and stuff availible via the web addon page ect. do all best practises making it secure and reliable."*

### Verification legend

Every factual claim below carries one of these:

| Tag | Meaning |
|---|---|
| **[MEASURED]** | I ran the command in this session and read the output. Reproducible command given. |
| **[PRIMARY]** | Read from vendor docs, the upstream repo, or an RFC. |
| **[SECONDARY]** | Read from a third-party source (blog, forum, search summary). Treat as a lead, not a fact. |
| **[UNVERIFIED]** | I could not confirm it. Stated so you can go confirm it, not so you can build on it. |

---

## 1. The recommendation, up front

**Use Stalwart Mail Server (community/AGPL edition) as the engine, deployed as a single-replica StatefulSet on RocksDB, with inbound mail self-hosted and outbound mail relayed through a reputable SMTP provider by default.**

That last clause is not a hedge, it is the design. The split — *inbound is yours, outbound is rented until you have earned an IP* — is what makes this project shippable rather than a six-month deliverability project that ends in Gmail's spam folder.

### The three facts that constrain everything else

**Fact 1 — This cluster's public IPv4 is a KPN consumer/business broadband address with a generic, unchangeable PTR.**

```
$ dig +short -x 203.0.113.10
84-82-69-110.fixed.kpn.net.
```
**[MEASURED]** ExternalDNS publishes `--default-targets=203.0.113.10` **[MEASURED]**, and RDAP puts that /16 under `KPN B.V.`, NL, abuse@kpn.com **[MEASURED]**.

Forward-confirmed reverse DNS (FCrDNS) — a PTR that resolves back to the sending host's HELO name — is a hard requirement at Google and Microsoft for bulk senders and a heavily-weighted signal for everyone else. On a KPN fixed-line you cannot set that PTR. **This single fact is why outbound-from-home cannot be the primary sending path.** Note the shape of the trap: the mail will *send*. It will get a 250. It will land in spam or be silently dropped, and you will find out weeks later from a customer.

The one piece of good news, and it is genuinely surprising:

```
$ exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25 && head -1 <&3
220 mx.google.com ESMTP a640c23a62f3a-c21237cb2efsi602210566b.237 - gsmtp
```
**[MEASURED]** — **outbound port 25 from 203.0.113.10 is NOT blocked.** KPN is not filtering egress 25. So the *mechanical* path exists; it is only reputation that fails. That distinction matters for the design: you can run real MTA-to-MTA delivery for low-stakes traffic (DMARC/TLS report submission, internal notifications) from home while relaying anything a human will read.

**Fact 2 — There is exactly one node in this fleet with a settable PTR, and it is 15 ms away across a stretched VLAN, and MetalLB has been told not to announce from it.**

`talos-prod-cp4` sits on Hetzner bare metal in Falkenstein:
```
$ dig +short -x 162.55.99.90
static.90.99.55.162.clients.your-server.de.
```
**[MEASURED]** — the Hetzner default PTR, which *is* user-editable in Hetzner Robot. `sites/hypatia.yaml` records `edge.host: 162.55.99.90` **[MEASURED]**.

But the same file declares two constraints that fight this idea:
```yaml
constraints:
  rtt_ms: 16
  metallb_speaker: exclude      # "a speaker on the edge node can win an ARP
                                #  election and pull VIP traffic across the WAN"
  longhorn_scheduling: disable
```
**[MEASURED]**

And the cluster does not currently honour either of them:
```
$ kubectl -n metallb-system get pods -o wide | grep speaker
metallb-speaker-z8lm7  Running  10.0.0.93  talos-prod-cp4   ← speaker IS running on hypatia
$ kubectl -n longhorn-system get nodes.longhorn.io -o custom-columns=NAME:.metadata.name,ALLOWSCHED:.spec.allowScheduling
talos-prod-cp4   true                                        ← Longhorn scheduling IS enabled
```
**[MEASURED]** Both are live drift against the declared intent. Whoever designs this must decide deliberately, not inherit an accident.

**Fact 3 — The platform's own domain already has production mail on Proton and Microsoft 365. Do not touch it.**

```
$ dig +short MX example.com
10 mail.protonmail.ch.
20 mailsec.protonmail.ch.
30 example-com.mail.protection.outlook.com.
$ dig +short TXT example.com
"v=spf1 a mx ip4:80.115.74.209 include:spf.protection.outlook.com include:_spf.protonmail.ch ~all"
$ dig +short TXT _dmarc.example.com
"v=DMARC1; p=quarantine"
```
**[MEASURED]** `example.com` is `BASE_DOMAIN` — it is what ExternalDNS filters on (`--domain-filter=example.com`) **[MEASURED]** — and it is also the operator's live personal mail. Authentik, Alertmanager and the console mailer all authenticate to `smtp-mail.outlook.com` with credentials from `secret/platform/authentik` **[MEASURED]**, so an MX change here breaks SSO password resets, invitations and alerting simultaneously.

The two test domains are genuinely available and genuinely different from each other:

| Domain | NS pair | MX | SPF | DMARC | Verdict |
|---|---|---|---|---|---|
| `infraweaver.net` | `adam` / `shaz`.ns.cloudflare.com | none | none | none | **Clean greenfield.** Ideal first target. |
| `infraweaver.cloud` | `adrian` / `tim`.ns.cloudflare.com | none | `v=spf1 a mx include:_spf.hostnet.nl -all` | `p=reject` | Website live behind CF proxy; SPF points at Hostnet; already `p=reject`. Second target. |
| `example.com` | `adrian` / `tim`.ns.cloudflare.com | Proton + M365 | Proton + M365 | `p=quarantine` | **Off limits.** |

**[MEASURED]** — all three delegate to Cloudflare, which confirms the operator's "i think those are in my cloudflare".

⚠️ **Note the nameserver pairs.** Cloudflare assigns a nameserver pair per *account*. `infraweaver.net` is on `adam`/`shaz` while the other two are on `adrian`/`tim`. That strongly suggests `infraweaver.net` lives in a **different Cloudflare account** than `infraweaver.cloud` and `example.com` — so **one API token will probably not cover both** [UNVERIFIED — confirm by listing zones with the token you intend to use]. This will bite on day one of the "add a domain and it sets all the DNS" feature if nobody checks first.

---

## 2. Is Stalwart the right engine?

### 2.1 The field

| | **Stalwart** | **Mailu** | **Mailcow** | **Maddy** | **Postfix+Dovecot+Rspamd** | **Chasquid** |
|---|---|---|---|---|---|---|
| Shape | Single Rust binary | ~8 containers | ~15 containers | Single Go binary | 3+ daemons, hand-assembled | Single Go binary, SMTP only |
| K8s support | Documented, StatefulSet, reference chart **[PRIMARY]** | Official Helm chart, `mailu-2.7.3` 2026-07-19 **[MEASURED]** | **None.** Docker Compose only **[SECONDARY]** | None official | None official | None official |
| SMTP | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| IMAP | ✅ | ✅ (Dovecot) | ✅ (Dovecot) | ✅ | ✅ (Dovecot) | ❌ |
| JMAP | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| DKIM sign + rotate | ✅ built-in, automated rotation **[PRIMARY]** | ✅ | ✅ | ✅ | ✅ (Rspamd) | ✅ |
| SPF/DKIM/DMARC/ARC verify | ✅ all four **[PRIMARY]** | ✅ | ✅ | partial | ✅ | partial |
| MTA-STS / DANE / TLS-RPT | ✅ all three **[PRIMARY]** | partial | partial | partial | via extra config | partial |
| Spam filter | Built-in: rules, statistical classifier, DNSBL, Pyzor, greylisting, reputation, ASN/GeoIP **[PRIMARY]** | Rspamd | Rspamd | rspamd hookup | Rspamd | basic |
| Storage backends | RocksDB, PostgreSQL, MySQL, SQLite, S3, Azure, FS, Redis **[PRIMARY]** | Postgres/SQLite + FS | MySQL + FS | FS + SQL | FS/Maildir + SQL | FS |
| Clustering | Community: coordination via Zenoh/Kafka/NATS/Redis **[PRIMARY]** | limited | ❌ | ❌ | manual | ❌ |
| **Automatic DNS record publishing** | ✅ **Cloudflare, Route53, Google, Azure, DigitalOcean, OVH, Bunny, Porkbun, DNSimple, Spaceship, deSEC, RFC 2136** **[SECONDARY→PRIMARY]** | ❌ | ❌ | ❌ | ❌ | ❌ |
| Admin API / web UI | Web admin (community) + HTTP API **[PRIMARY]** | Web UI + API | Web UI + API | config file only | config files only | config files only |
| Licence | AGPL-3.0 + SELv2 dual **[PRIMARY]** | MIT | GPL-3.0 | GPL-3.0 | mixed OSS | Apache-2.0 |
| Release cadence | **~weekly** (v0.16.17 2026-08-10, 12 releases since 2026-05-20) **[MEASURED]** | steady | steady | v0.9.5 2026-05-23, 6k★ **[MEASURED]** | distro-paced | v-slow, 977★ **[MEASURED]** |

### 2.2 Why Stalwart wins here

**It answers the operator's headline requirement natively.** *"if i add a domain to the mailing it will set all the correct mailing infromation dns wise"* is not a feature you have to build — Stalwart has **automatic DNS management** that publishes and refreshes MX, SPF, DKIM, DMARC, SRV, CAA, TLSA, MTA-STS, TLS-RPT, autoconfig and autodiscover records **directly against the Cloudflare API** [SECONDARY, from Stalwart docs via search; **verify against `/docs/install/dns/` and the `DnsServer`/`dnsManagement` schema before designing on it**]. Every other candidate in the table would make you write a Cloudflare reconciler by hand — which is exactly the kind of security-critical, half-tested glue that eventually publishes a wrong SPF record and blackholes a customer's mail.

**Operability matches this cluster.** One container, one PVC, one StatefulSet. Compare Mailu (~8 containers) or Mailcow (~15, and no Kubernetes story at all). This cluster has 8 GB of headroom on a good day and OOM-killed a build today; a fifteen-container mail stack is not a serious proposal here.

**It is honest about the community/enterprise line.** The Enterprise-only list is narrow and, critically, does *not* include anything this project needs: multi-tenancy with per-tenant isolation, per-tenant branding, account archiving/un-deletion, live telemetry dashboards, AI/LLM spam classification, AI Sieve, masked email, read replicas and sharded storage, and per-domain directory backends **[PRIMARY, /compare]**. Community keeps: **clustering and coordination, LDAP/AD/SQL directories, OAuth 2.0, OIDC, TOTP, the full non-AI spam stack, the web admin UI, all storage backends, and unlimited client domains** **[PRIMARY]**.

⚠️ But read that list again for what it means operationally: **"multi-tenancy with per-tenant quotas and isolation" is Enterprise.** The community edition is explicitly *single-tenant with unlimited domains*. Hosting mail for several WordPress client sites is therefore **many domains inside one tenant**, not many tenants. Isolation between those domains is by mailbox ACL and per-domain config, not by a tenancy boundary. If the eventual product story is "each agency client gets a sealed compartment", that is a licence purchase, not a configuration.

**Security track record is short but the response is fast and independently checked.** A second external audit ran 2026-09-09 → 2026-09-25 2025 against v0.13.2, crystal-box (code review + exploitation), OWASP Top 10 and protocol analysis. Seven findings: 2 high, 5 low. Both highs were memory-exhaustion DoS — CVE-2025-59045 (CalDAV recurring-event expansion, ~2 GB from one request, ≤0.13.2) and CVE-2025-61600 (unbounded allocation in the IMAP parser, ≤0.13.3, fixed 0.13.4). **Most findings were fixed within four hours.** The full report is public. **[PRIMARY, stalw.art/blog/security-audit-2025]**

That is a good record *for a young codebase* — memory-safety-class DoS in Rust, no RCE, no auth bypass, public disclosure, fast fixes, and a repeat paid audit. It is not the record of Postfix, which has had two decades to be wrong in public.

### 2.3 The strongest argument against Stalwart — stated properly, not strawmanned

**Stalwart is a young, single-vendor, fast-moving codebase that you are about to make the front door for other people's business email, and its state model is not GitOps-shaped.**

Four concrete edges, all verified:

1. **The upgrade treadmill is real.** Twelve releases between 2026-05-20 and 2026-08-10 — roughly one per week **[MEASURED]**. Pinning to `v0.16` and never looking again is how you sit on the next CVE-2025-61600 for a month. Tracking `latest` on a mail server is how you find out at 03:00 that a schema migration ran. Neither is comfortable. Postfix+Dovecot on a distro's security-patch stream is genuinely lower-effort here, and pretending otherwise is dishonest.

2. **The config is not a file you own.** The setup wizard *writes* `config.json` into `/etc/stalwart` and provisions the rest into the data store **[PRIMARY]**. Settings live in the database and are edited through the web admin. That directly contradicts this repo's operating model, where the git tree is the source of truth and ArgoCD reconciles it. You will have a component whose real configuration is **inside a PVC**, invisible to `git diff`, invisible to ArgoCD, and restorable only from a volume backup. This repo has already been burned by exactly this shape — eight ArgoCD apps managing zero resources, `core/rbac` committed-but-never-applied. Plan for it explicitly or it will happen again.

3. **The management API is thinner than it looks.** `/api/auth`, `/api/account`, `/api/schema/{hash}` (read-only), `/api/live/delivery/{target}` for SSE diagnostics; auth via Bearer, Basic, or a short-lived `?token=` **[PRIMARY]**. The docs do **not** describe REST endpoints for creating domains, accounts or DKIM keys — those appear to go through the web admin or CLI **[PRIMARY, and this is a gap, not a summary artefact]**. Since the operator's requirement is *"make all features and security settings and stuff availible via the web addon page"*, **the addon's console page is going to have to drive something. Which something is the single biggest unknown in this whole document** — see Open Questions Q1.

4. **Not all settings apply live.** BlockedIp/AllowedIp changes made via the settings API persist but do not affect live connections until a full process restart **[SECONDARY, Stalwart support forum]**. Removing the recovery admin or deleting the HTTP listener also requires a restart **[SECONDARY]**. A console page whose "Block this IP" button silently does nothing until the next pod restart is worse than no button.

**When I would change my answer.** If the design phase discovers that domain/account/DKIM provisioning has no scriptable interface at all — no REST, no usable CLI — then the console addon degrades to "a link to Stalwart's own web admin", the operator's core requirement is unmet, and **Mailu becomes the better choice**: an official, versioned, actively-released Helm chart (`mailu-2.7.3`, 2026-07-19 **[MEASURED]**) and a documented admin API, at the cost of eight containers, no JMAP, and hand-writing the Cloudflare DNS reconciler yourself. That is a real trade, not a fallback.

---

## 3. Deployment shape on Kubernetes

### 3.1 Ports — what must face the internet, and what must never

| Port | Protocol | Public? | Reasoning |
|---|---|---|---|
| **25** | SMTP (MTA→MTA, STARTTLS) | **Yes, unavoidable** | This is the whole point of inbound. Must accept cleartext-then-STARTTLS from arbitrary hosts; you cannot require auth or TLS-first here without silently losing mail. |
| **465** | Submission, implicit TLS | Yes | Client submission. Stalwart's own hardening guide prefers 465 and says to **disable 587** if you use it **[PRIMARY]**. |
| **993** | IMAPS | Yes (or VPN-only) | Only if humans use real mail clients. If the mailing addon is machine-to-machine only (WordPress relay + a console UI), **do not expose it.** |
| **443** | HTTPS — JMAP, web admin, OAuth, ACME, autoconfig, **MTA-STS policy** | Yes | Stalwart: *"This port must remain open in nearly all deployments"* **[PRIMARY]**. Already solved here — Traefik terminates it. |
| 587 | Submission, STARTTLS | **No** | Redundant with 465. Disable. |
| 143 | IMAP cleartext | **No** | Disable. |
| 110 / 995 | POP3 | **No** | Obsolete. Disable. |
| 4190 | ManageSieve | **No** unless Sieve is exposed to users | Disable. |
| **8080** | HTTP management | **NEVER** | Stalwart: *"strongly recommended to disable this port after setup is complete"* **[PRIMARY]**. If it must live, bind it to the pod only and reach it from the console over ClusterIP. |

Stalwart's hardening page also says to define **HTTP Access Control rules** to switch off endpoints you do not use — WebDAV, metrics — on internet-facing servers, and never to use an administrator account for IMAP/JMAP/WebDAV **[PRIMARY]**.

### 3.2 Workload shape

**StatefulSet, one replica, `volumeClaimTemplates`.** Stalwart's Kubernetes guidance states the StatefulSet shape is used *"so that each replica keeps a stable hostname and its own PersistentVolumeClaim"* and that with local backends **each pod needs its own PVC — a shared RocksDB volume corrupts** **[PRIMARY]**. RocksDB is *"the recommended backend for single-node installations"* **[PRIMARY]**.

Multi-replica requires moving state to PostgreSQL/S3 and adding a coordination backend. **Do not do this in v1.** A three-node cluster where one node is 15 ms away across a WAN is a bad place to learn a new coordination protocol, and the failure mode of a split-brain mail store is lost mail.

⚠️ **There is no official Stalwart Helm chart.** ArtifactHub shows six community charts (`stalwart-helm/stalwart 0.7.13`, `andibraeu/stalwart 1.0.2`, `stalwart-mail/stalwart-mail 2.0.7`, `l4g/stalwart-mail-ha 0.1.2`, `antigenic-stalwart-helm-chart 1.0.5`, `pulsedev/stalwart-mail 0.0.5`) and **every one reports `official: false`** **[MEASURED via ArtifactHub API]**. The Stalwart docs present their chart as *"a minimal, complete reference… or used as a starting point for a site-specific chart"*, not as a hosted repo **[PRIMARY]**. **Conclusion: write plain manifests under `kubernetes/catalog/mailing/manifests/`.** That matches how `vaultwarden` is already done here (`catalog.yaml` + `manifests/{deployment,pvc,secrets,ingressroute}.yaml`) **[MEASURED]**, and it avoids taking a dependency on an unowned third-party chart for the most security-critical service on the cluster.

### 3.3 The Kyverno collision — resolve this before writing a single manifest

Live cluster policies **[MEASURED, `kubectl get cpol`]**: `require-non-root`, `require-drop-all-capabilities`, `require-drop-all-capabilities-wide`, `disallow-privileged-containers`, `disallow-privilege-escalation`, `disallow-hostpath-volumes`, `disallow-host-namespaces`, `require-pod-probes`, `require-resource-limits`, `require-memory-request-and-limit`, `limit-memory-burst-ratio`, `require-seccomp-profile`, `disallow-latest-tag`.

Three of these hit a mail server directly:

- **`require-non-root` + `require-drop-all-capabilities` vs ports below 1024.** The Stalwart container runs as unprivileged `stalwart`, **UID 2000**, and the binary carries the `cap_net_bind_service` **file capability** to bind low ports without `--privileged` **[PRIMARY]**. Dropping ALL capabilities removes that from the permitted set, so **the file capability stops working.** → **Bind high ports inside the container (2525 / 4465 / 9993 / 8443) and let the Service map 25/465/993/443 onto them.** A `LoadBalancer` Service does this for free. Do not reach for `NET_BIND_SERVICE`; do not reach for `hostPort`.
- **`require-pod-probes`.** Satisfied natively: Stalwart exposes `/healthz/live` and `/healthz/ready` on the management listener **[PRIMARY]**. Note the tension with §3.1 — the management listener you want closed to the world is the one carrying the probes. Bind it to the pod IP and probe it there.
- **`disallow-latest-tag`.** Pin `stalwartlabs/stalwart:v0.16.x` by digest. The `v<major>.<minor>` tag is the vendor's own production recommendation **[PRIMARY]**; `latest` is refused by the cluster anyway.

### 3.4 The network-policy collision

`generate-default-deny-cnp` is a `ClusterPolicy` with `synchronize: true` that auto-creates an `auto-default-deny` CiliumNetworkPolicy in **every namespace not on its exclude list** **[MEASURED, full policy body read]**. A new `mailing` namespace is not on that list, so it gets:

- **Ingress:** intra-namespace only, plus the `traefik` namespace, plus Prometheus **on metrics ports only**.
- **Egress:** intra-namespace, plus kube-dns on 53.

That posture blocks **every single thing a mail server does**: no inbound SMTP from the world, no outbound SMTP to anywhere, no DNS to public resolvers for MX/SPF/DKIM/DNSBL lookups.

**Do not add `mailing` to the Kyverno exclude list.** Cilium policies are additive — ship a second, explicit CNP in the namespace that allows exactly:
- ingress `fromEntities: [world]` → mail ports only;
- egress to `world` on **25** (delivery), **53** (DNS: MX, SPF, DKIM, DMARC, DNSBL, MTA-STS), **443** (ACME, MTA-STS policy fetch, DNS provider API);
- egress to the chosen relay's submission endpoint.

The default-deny stays, self-heals, and the allow-list is one reviewable file. This also means the CNP *is* the "as closed off as possible" artefact the operator asked for — it should be rendered on the addon page, not hidden in git.

### 3.5 Storage, and what breaks when the pod moves

**What must be durable:** the RocksDB data directory (`/var/lib/stalwart`) — every message, mailbox, account, ACL, Sieve script, **and the DKIM private keys** — plus `/etc/stalwart` (`config.json`) **[PRIMARY]**.

**Growth:** unbounded and monotonic. Mail only grows unless quotas or retention are enforced. Set per-account quotas from day one; an unquota'd mail store is a disk-full outage waiting for a schedule.

**What breaks when the pod moves — the specific local hazard.** This repo has a documented, expensive precedent: *"retiring a node strands **local-path** PVCs that NO Longhorn check sees (took out authentik SSO + openbao)"*. Storage classes available **[MEASURED]**: `local-path` (default), `local-path-retain`, `longhorn`, `longhorn-game`, `longhorn-retain`, `longhorn-static`.

- **`local-path`** → the pod is welded to one node. Node dies, mail dies, and Longhorn's dashboards will show nothing wrong. **Refuse.**
- **`longhorn-retain`** → replicated, survives a node loss, `Retain` protects against an accidental PVC delete. **This is the right choice**, with one caveat: Longhorn replication across the hypatia link is exactly what corrupted volumes on 2026-08-14 when host MTU (1500) exceeded the overlay MTU (1370) — *"volumes faulted cluster-wide… while every ping and every small API call kept working"* **[MEASURED, sites/hypatia.yaml]**. If a Longhorn replica for the mail volume lands on cp4, you are betting mail integrity on that MTU being right on every node, forever. **Constrain replica placement to the two local zones.**
- RocksDB on a network-replicated block device is also a real performance question. Stalwart says RocksDB is *"well suited to fast storage devices such as SSDs"* **[PRIMARY]**; the docs are **silent** on network filesystems and on unclean-shutdown behaviour **[PRIMARY — the absence is the finding]**. **[UNVERIFIED]** whether Longhorn's latency profile is acceptable for a RocksDB mail store at this scale. Measure before committing.

**Zone pinning.** Per this repo's hard-won rule: zones are `proxmox` / `microserver` / `hypatia`, and **cp3 is its own zone**, so the correct affinity is `zone NotIn [hypatia]` — never `zone In [proxmox]`, which silently pins to a single node. `scripts/fleet-topology.yaml` exists precisely to make a stale rule fail CI; add the mailing rule there **[MEASURED]**.

### 3.6 TLS certificates

Two independent options, and the choice matters:

- **cert-manager (recommended).** Already live with `letsencrypt-dns` and `letsencrypt-http` ClusterIssuers, both `Ready` **[MEASURED]**. DNS-01 via Cloudflare issues wildcards and works for hosts that are not HTTP-reachable — which is precisely the SMTP/IMAP case. Stalwart then reads the cert from a mounted Secret.
- **Stalwart's built-in ACME.** Supported **[PRIMARY]**, but it needs its own port-80/443 or DNS-01 credentials, duplicating a solved problem and putting a second ACME client on the same domains.

Use cert-manager. **But note the reload question:** a cert-manager renewal rewrites the Secret; whether Stalwart picks up rotated certs from disk without a restart is **[UNVERIFIED]**. If it does not, every 60 days the mail server serves an expired cert until something restarts it. Test this deliberately — it is the kind of thing that is invisible for two months and then breaks everything at once.

### 3.7 Backup and restore — the part that is worse than it looks

Stalwart's documented backup tool is **Vandelay**, and it is **per-account JMAP import/export to a SQLite archive**:
```bash
export VANDELAY_PASSWORD='account-app-password'
vandelay import jmap --url https://jmap.example.com --auth-basic user@example.com \
  --account-name user@example.com /backups/alice.sqlite
```
It runs online, is convergent (safe to re-run, incremental), and covers mailboxes, messages, calendars, contacts, Sieve scripts, identities and files. **[PRIMARY]**

⚠️ **It explicitly does NOT cover server configuration, access controls, DKIM keys, or account provisioning** — *"these remain outside the account model"* **[PRIMARY]**. And it is **one archive per account**.

So a real restore story needs three tracks, and a design that names only one of them is a design that loses your DKIM keys:

1. **Volume-level** — Longhorn snapshot/backup of the PVC. Captures everything including config and DKIM keys. Crash-consistent only; RocksDB's recovery behaviour under an unclean snapshot is **[UNVERIFIED]**.
2. **Per-account logical** — Vandelay, scheduled per mailbox. This is what gives you granular "restore one user's mailbox" and portability off Stalwart entirely.
3. **Configuration** — an export of the settings tree and the DKIM private keys, into OpenBao. **Losing DKIM private keys is not recoverable by rotating them**: mail already in flight and archived signatures break, and every receiving cache that holds your selector sees a mismatch during the gap.

Velero is live with four daily/weekly schedules **[MEASURED]** and covers the local-path PVCs Longhorn cannot snapshot — a `mailing` schedule belongs there too.

**The restore drill is the deliverable, not the backup.** A backup you have never restored is a hypothesis.

---

## 4. Deliverability reality — the blunt version

### 4.1 What will not work without provider cooperation

**From 203.0.113.10 (KPN fixed line):**
- ❌ You cannot set the PTR. FCrDNS will never pass.
- ❌ Consumer/broadband ranges are the canonical content of the Spamhaus PBL. **[UNVERIFIED for this specific IP]** — I attempted the check and Spamhaus refused the query:
  ```
  $ dig +short A 110.69.82.84.zen.spamhaus.org   → 127.255.255.254
  $ dig +short A 2.0.0.127.zen.spamhaus.org      → 127.255.255.254   ← control that MUST be listed
  ```
  `127.255.255.254` is Spamhaus's "query refused — public/open resolver" response, and the control returning it proves the queries never ran. Re-check via Spamhaus's web lookup or a DQS key. **Do not read my empty result as "not listed".**
- ⚠️ Inbound port 25 reachability was **not tested** — I verified egress only. Whether the KPN router forwards 25 inbound to `10.0.0.200` is **[UNVERIFIED]** and is a five-minute test that must happen before any design is finalised.
- ✅ Outbound 25 is open **[MEASURED]** — see Fact 1.

**From 162.55.99.90 (Hetzner Falkenstein):**
- ✅ PTR is settable in Hetzner Robot.
- ⚠️ Hetzner blocks outbound 25 by default on new servers and unblocks on request; commonly reported as automatic after ~24–48h of abuse screening, and formally *"only possible after the first paid invoice"* **[SECONDARY]**. Current status for **this** account is **[UNVERIFIED]** — check the Robot panel and test from the host.
- ❌ MetalLB cannot currently be used to land a public VIP here: it is L2, the speaker on cp4 winning an ARP election would pull VIP traffic across the WAN (the exact thing `metallb_speaker: exclude` warns about), and the announced pool `10.0.0.200`, `10.0.0.202-210` is **RFC1918** **[MEASURED]** — private addresses on the home VLAN, not routable from Hetzner.

**Through Cloudflare:** ❌ MX records cannot be proxied. Cloudflare rewrites an MX pointing at a proxied hostname by prepending `_dc-mx` so mail bypasses the proxy entirely **[SECONDARY, CF docs]**. Arbitrary-TCP proxying is **Spectrum, Enterprise-only** **[SECONDARY]**. So: **the mail host's A record must be DNS-only (grey cloud), and it will expose your real IP.** That is a genuine, unavoidable information disclosure — the one hole in "as closed off as possible", and it should be stated on the addon page rather than discovered.

### 4.2 The honest architecture

```
INBOUND  (self-hosted — reputation does not gate receiving)
  internet :25 ──► MX mail.infraweaver.net ──► [DNS-only A record]
                                              ──► public IP :25
                                              ──► MetalLB VIP 10.10.0.20x
                                              ──► Stalwart :2525

OUTBOUND (relayed by default — reputation is entirely the relay's)
  Stalwart ──► smarthost :465 (authenticated) ──► provider ──► recipient
             └─ SPF: include:<provider>   DKIM: signed by Stalwart, key yours
```

**Why this split is right, not lazy.** Inbound has no reputation gate — anyone can receive mail. Outbound is where a decade of IP reputation, feedback loops and blocklist relationships is priced in, and you cannot manufacture that on a KPN line. Signing DKIM yourself with your own key while relaying transport means **you keep domain alignment and portability** — DMARC passes on your key, and switching relays later is an SPF edit, not a migration.

### 4.3 If you insist on self-hosted outbound

Then all of this is mandatory, not optional:

- **PTR = HELO name, both directions.** `162.55.99.90` → `mail.infraweaver.net` → `162.55.99.90`.
- **Warm-up.** Start at single-digit volumes/day and roughly double weekly. A cold IP that sends 5,000 messages on day one is a blocked IP on day two.
- **Feedback loops.** Register with the ones that exist: Microsoft SNDS/JMRP, Yahoo/AOL CFL, and others. **Google has no classic FBL** — you get Postmaster Tools instead, and it only shows data above a volume threshold you probably will not reach.
- **Blocklist monitoring, continuously.** Spamhaus (SBL/CSS/PBL/XBL), Barracuda, SpamCop, SORBS, UCEPROTECT. This is a scheduled check with an alert, not a thing you look at after a complaint.
- **Bounce handling that actually suppresses.** Parse DSNs, distinguish 4xx (retry) from 5xx (suppress permanently), and *enforce* the suppression list. Repeatedly mailing dead addresses is the single fastest way to get listed.
- **Complaint handling.** ARF reports → immediate unsubscribe. A complaint rate above ~0.1% at Microsoft/Google is a throttle; above ~0.3% is a block.
- **DMARC aggregate reports (`rua=`) from day one**, and *read them*. This is your only view of what receivers actually do with your mail.
- **Start at `p=none`**, watch reports for weeks, then move to `quarantine`, then `reject`. Note `infraweaver.cloud` is **already at `p=reject`** **[MEASURED]** — publishing a new sending source there without first getting alignment right means those messages are **rejected**, not junked. That domain is the *harder* test, not the safer one.

### 4.4 Relay candidates

Do not pick on price alone. The properties that matter: does it allow **your** DKIM key (domain alignment), does it expose bounce/complaint webhooks, does it publish a stable SPF include, and does it let you send from many customer domains.

Categories: transactional API+SMTP providers (Postmark, Resend, SendGrid, Mailgun, SparkPost, Brevo, MailerSend, SMTP2GO, Mailjet, Elastic Email, Mandrill, ZeptoMail), and hyperscaler infrastructure (Amazon SES — cheapest at volume, more setup, own reputation-management burden).

⚠️ **You already have every one of these implemented.** See §6.

---

## 5. What this cluster already gives you

Read-only survey, 2026-08-16. **Reuse these; do not rebuild them.**

| Capability | State | Use it for |
|---|---|---|
| **cert-manager** | 7 ClusterIssuers, all `Ready`: `letsencrypt-dns`, `letsencrypt-http`, both staging variants, `infraweaver-ca`, `infraweaver-ca-selfsigned`, `selfsigned` **[MEASURED]** | SMTP/IMAP/HTTPS certs via DNS-01. Use **staging** while iterating — LE rate limits are per-domain-per-week and you will hit them. |
| **Traefik v3.3.4** | Entrypoints: `web:8000`, `websecure:8443`, `metrics:9100`, plus **custom TCP entrypoints already in production** — `registry:5005`, `teleport-auth:3025`, `teleport-node:3023`, `teleport-proxy:3024`, `extra-port:30032` **[MEASURED]** | **Yes, Traefik can do this** — those Teleport entrypoints are exactly the pattern. Stalwart even documents Traefik, requiring **PROXY protocol v2** (`proxyProtocol.version=2`) and `tls.passthrough=true` for SMTPS/IMAPS while port 25 stays un-passthrough so Traefik can inject the header **[PRIMARY]**. |
| **MetalLB** | `vlan3-pool`: `10.0.0.200/32` + `10.0.0.202-210`; `dns-pool`: `10.0.0.201/32`. Speakers on cp1, cp3 **and cp4**. Traefik LB is `externalTrafficPolicy: Local` **[MEASURED]** | ~8 free VIPs. **A dedicated `LoadBalancer` Service with `externalTrafficPolicy: Local` preserves source IP with no PROXY protocol and no Traefik in the path.** See §5.1. |
| **ExternalDNS v0.21.0** | Cloudflare provider, `--domain-filter=example.com`, `--policy=upsert-only`, `--txt-owner-id=infraweaver-prod`, `--txt-prefix=edns-`, `--annotation-filter=…managed in (true)` **[MEASURED]** | **Scoped to the wrong domain and the wrong record types.** It will not touch `infraweaver.net`/`.cloud` without a filter change, and `upsert-only` means it never deletes. It manages A records for Services/IngressRoutes — it is not an MX/DKIM/DMARC/MTA-STS publisher. **Stalwart's own DNS management is the better fit; ExternalDNS is not the tool for this job.** |
| **Cilium v1.17.4** | Namespace-scoped CNPs in use; **zero** `CiliumClusterwideNetworkPolicy` **[MEASURED]** | Additive allow-list beside the Kyverno default-deny. See §3.4. |
| **Kyverno** | 24 ClusterPolicies, `Ready` **[MEASURED]** | Constraints, not features. See §3.3. |
| **OpenBao + External Secrets** | `ClusterSecretStore` named `openbao`; established pattern `catalog.yaml: secrets.path/keys` → `scripts/seed-catalog-secrets.sh` → `secret/data/platform/<app>` → `ExternalSecret` **[MEASURED, vaultwarden]** | Relay credentials, admin password, **DKIM private keys**, Cloudflare API token. ⚠️ Repo-documented trap: under `deletionPolicy: Retain`, **one missing property aborts the entire Secret**, not just that key. |
| **Longhorn** | 41 volumes; classes `longhorn`, `longhorn-retain`, `longhorn-static`, `longhorn-game`; scheduling enabled on all three nodes including cp4 **[MEASURED]** | `longhorn-retain`, replicas constrained off `hypatia`. |
| **Velero** | 4 schedules: `velero-daily-objects`, `velero-daily-wordpress`, `velero-daily-gamehub`, `velero-weekly-localpath` **[MEASURED]** | Add a `mailing` schedule. Object-level restore is the thing an etcd snapshot cannot give you. |
| **Monitoring** | kube-prometheus-stack + Loki + Alertmanager, `core-monitoring` enabled **[MEASURED]**. Auto-default-deny permits Prometheus scrape on metrics ports only. | Queue depth, deferred/bounced counts, DNSBL status, cert expiry, auth-failure rate. |
| **Gatus** | Live, `status.int.${BASE_DOMAIN}` **[MEASURED]** | External probes for 25/465/993 and the MTA-STS policy URL. ⚠️ Repo precedent: Gatus 404'd for 25 days while ArgoCD reported Synced/Healthy. |
| **Catalog pattern** | `kubernetes/catalog/<app>/{catalog.yaml,values.yaml,manifests/}` → `platform.yaml: catalog.enabled` → `scripts/sync-catalog.sh` → `kubernetes/bootstrap/` → ArgoCD **[MEASURED]** | The deployment path for `mailing`. ⚠️ Repo precedent: **eight ArgoCD apps managed zero resources** because `directory.recurse` was missing. Verify the app actually manages resources after the first sync. |
| **Console addon SDK** | `src/addons/{gamehub,wiki,wordpress-manager}/`, `addon.manifest.ts` with `navItems`/`pages`/`podTabs`/`permissions`, `AddonPageHost` + generated route shims, `ADDON_PAGE_LOADERS`, `create-infraweaver-addon` scaffolder **[MEASURED]** | The `mailing` addon page. `wordpress-manager`'s manifest (17 pages, 4 permission tiers, per-page `requiredPermissions`, redirects for retired paths) is the reference. |

### 5.1 Traefik TCP vs. a dedicated LoadBalancer — pick deliberately

Both work. They fail differently.

**Traefik `IngressRouteTCP`** — reuses the existing ingress path and one VIP, but needs a new entrypoint per port, needs **PROXY protocol v2** end-to-end plus `proxyTrustedNetworks`/`overrideProxyTrustedNetworks` on every Stalwart listener **[PRIMARY]**, and puts the platform's entire HTTP ingress in the blast radius of a mail-port misconfiguration. Get the PROXY config wrong and Stalwart sees Traefik's pod IP as the client — at which point **SPF and DMARC evaluate against the wrong address, greylisting is meaningless, rate limits apply per-proxy instead of per-sender, and auto-ban blocks Traefik.** Stalwart's docs say this plainly: without PROXY protocol those checks *"are meaningless"* **[PRIMARY]**.

**A dedicated `LoadBalancer` Service with `externalTrafficPolicy: Local`** — takes one VIP from the ~8 free, preserves source IP natively with **no PROXY protocol at all**, keeps mail traffic entirely out of Traefik, and matches the precedent already set by the Traefik LB itself (`externalTrafficPolicy: Local` **[MEASURED]**). Cost: a second public entry point to firewall and monitor, and `Local` means only nodes running the pod answer — which interacts with MetalLB L2 failover and with the cp4 speaker question in Fact 2.

**Recommendation: dedicated LoadBalancer.** Source-IP fidelity is not a nice-to-have for a mail server; it is the input to every anti-abuse decision the server makes. Removing an entire moving part from that path is worth one VIP.

---

## 6. WordPress integration — mostly already built

This is the pleasant surprise. **Do not build a WordPress mail integration. One already exists, it is good, and the correct move is to add one class to it.**

`apps/infraweaver-wp-connector/includes/` **[MEASURED]** contains:

- **`class-iwsl-mail-registry.php`** — the single registration point. Its own header: *"ADDING A PROVIDER IS ONE LINE. all() is the single registration point: the picker, the wizards, the save validator, the signed console snapshot and the send path all read from here. No admin edits, no new endpoints, no new nonces, no switch statements anywhere — that is the entire point of the `IWSL_Mail_Method` contract."*
- **16 implemented methods** **[MEASURED]**: `smtp`, `ses`, `brevo`, `elasticemail`, `mailersend`, `mailgun`, `mailjet`, `mailtrap`, `mandrill`, `postmark`, `resend`, `sendgrid`, `smtp2go`, `sparkpost`, `zeptomail`, plus the `api` base class.
- **`class-iwsl-mail-oauth-methods.php`**, `class-iwsl-mail-methods-token.php`, `class-iwsl-mail-methods-keyed.php` — the credential shapes.
- **`class-iwsl-smtp-transport.php`**, `class-iwsl-mail-message.php` (RFC 822 rendering), `class-iwsl-email-delivery.php`.
- **`class-iwsl-deliverability.php` — the "Deliverability Doctor"**, which already *"resolves the sending domain's records, says whether the transport that is actually configured is authorised by the SPF record that actually exists, reads the DMARC policy and translates it into what receiving servers will DO"*, and reports **UNKNOWN rather than pass** when a check cannot run.
- **Newsletter suite**: `class-iwsl-newsletter{,-queue,-form,-campaigns,-hygiene}.php`.

**The integration is therefore:**

1. **One new `IWSL_Mail_Method`** — "InfraWeaver Mail" — whose fields are the cluster submission host, port 465, and a **per-site application password** minted by the mailing addon. One class, registered in `all()`. That is the whole transport change.
2. **The console provisions it, not the site owner.** The mailing addon creates the mailbox/app-password and pushes it to the site through the existing connector RPC. Nobody types a mail password into a website — which is exactly the concern the registry's own header raises about the `smtp` method being deliberately ordered last.
3. **The Deliverability Doctor becomes the acceptance test.** It already knows how to say "the SPF record that exists does not authorise the transport you configured." Point it at a site switched to InfraWeaver Mail; a green verdict is real evidence, not a claim.
4. **Per-site DKIM alignment.** Each WordPress site sends `From:` its own domain; Stalwart signs with that domain's key; the mailing addon publishes the selector to Cloudflare. This is the payoff of self-hosting: alignment without every client needing a relay account.

⚠️ The connector's `email_delivery` feature flag gates the Doctor. A brand-new entitlement *"would ship LOCKED on every live site until the console's tier definitions granted it — a feature nobody could open"* **[MEASURED, source comment]**. Ride the existing flag.

---

## 7. Security posture

### 7.1 What "as closed off as possible" can honestly mean

It cannot mean "no unauthenticated internet exposure". Port 25 must accept connections from arbitrary hosts, without authentication, in cleartext-then-STARTTLS, or the server does not receive mail. That is the protocol. Anyone promising otherwise is describing a relay-only service, not a mail server.

What it *can* mean, and what the addon page should therefore actually show:

1. **Four ports open, not twelve.** 25, 465, 993, 443 — everything else off (§3.1), with the closed list rendered as a first-class fact, not an implementation detail.
2. **Default-deny network posture that self-heals**, with the allow-list as one auditable CNP (§3.4).
3. **The management port never leaves the pod.** The console reaches it over ClusterIP; the internet cannot.
4. **No credential ever lands in git.** OpenBao + ESO for the relay password, admin password, DKIM keys and the Cloudflare token — the pattern already proven by `vaultwarden` and the console mailer.
5. **Admin accounts are never mail accounts.** Stalwart says this explicitly **[PRIMARY]**. Separate identities, least-privilege roles.
6. **Every mailbox gets an application password, not a login.** Revocable per consumer, so a compromised WordPress site is one revocation, not a domain-wide incident.

### 7.2 Attack surface, per port

| Port | Who can reach it | Threats | Mitigations available |
|---|---|---|---|
| **25** | Anyone on the internet | Spam floods, dictionary/RCPT enumeration, open-relay probing, STARTTLS stripping, protocol-parser DoS (**this is exactly CVE-2025-61600's class**) | Greylisting, DNSBL, SPF/DMARC/ARC verification, reputation tracking, ASN/GeoIP blocking, per-IP rate limits, auto-ban, connection caps, message-size caps — **all built in and all community-edition** **[PRIMARY]** |
| **465** | Anyone (auth required) | Credential stuffing, spray, relay abuse via a stolen credential | Strong SASL, **app passwords with per-account send rate limits**, TOTP where interactive, auto-ban on repeated failures, alert on outbound-volume anomaly |
| **993** | Anyone, if exposed | Credential attacks, mailbox exfiltration, IMAP-parser DoS | **Prefer not exposing it at all.** If exposed: app passwords, auto-ban, and treat CVE-2025-61600 as the template for what an IMAP parser bug costs. |
| **443** | Anyone | Web-admin auth attacks, JMAP abuse, XSS in the admin SPA, ACME/autoconfig probing | HTTP Access Control rules to disable unused endpoints **[PRIMARY]**; **strongly consider putting the web admin behind Authentik forward-auth** using the platform's existing `forward-auth` middleware **[MEASURED, platform.yaml `authMiddleware: forward-auth`]** rather than exposing Stalwart's own login to the internet. |

### 7.3 Open-relay prevention

Non-negotiable and testable: **port 25 must accept mail only for domains this server is authoritative for; port 465 must require authentication before accepting any recipient.** A misconfigured relay is on a blocklist within hours and stays there for months.

This deserves an automated test in CI or a scheduled probe — attempt to relay a message for an unrelated domain through both ports and **assert rejection**. Given this repo's history of controls that report success while doing nothing (*"six findings were ONE shape: a control that could not work while reporting success"*), the open-relay check should fail loudly and visibly on the addon page, not sit in a log.

### 7.4 Authentication

Community edition provides **internal directory, LDAP/Active Directory, SQL directory, OAuth 2.0, OpenID Connect, and TOTP** **[PRIMARY, /compare]**. Authentik is already the platform IdP with OIDC live for the console and ArgoCD.

⚠️ **But OIDC does not solve IMAP/SMTP client auth.** Mail clients speak SASL; they do not run a browser OAuth flow (XOAUTH2 exists but support is uneven and it still needs a token broker). **Application passwords are the practical answer for machine and client access**, with OIDC reserved for the web admin and JMAP. Design for both; do not assume SSO covers the mail protocols.

Also note the repo's own scar tissue here: two separate incidents where a restore left Authentik's **join tables** empty — `authentik_core_user_groups` = 0 rows, and `authentik_core_provider_property_mappings` = 0 for 20 providers — so group-conferred superuser died and OIDC tokens carried no `email`/`groups` while every dashboard read "healthy". **A mail server whose authorization depends on Authentik groups inherits that failure mode.** Consider a directory-independent break-glass admin path.

### 7.5 Rate limiting

Three independent layers, all needed:
- **Inbound per-remote-IP** — connections/hour, messages/connection, recipients/message.
- **Outbound per-account** — the containment boundary when a WordPress site is compromised. A site that suddenly sends 10,000 messages should be throttled and alerted on automatically, not discovered from a blocklist entry.
- **Auth failures** — auto-ban. Stalwart has built-in detection for brute force, account enumeration, vulnerability scanning and SYN floods **[PRIMARY]**.

⚠️ Remember §2.3(4): **BlockedIp/AllowedIp changes may not take effect on live connections until a process restart** **[SECONDARY]**. Verify this against v0.16 before shipping a console button that implies immediacy.

---

## 8. Open questions for the design phase

These cannot be settled by reading. Each names who/what decides it.

**Q1 — What, exactly, can be automated in Stalwart? (Blocking; everything else depends on it.)**
The operator wants *"all features and security settings and stuff availible via the web addon page"*. The published management API is `/api/auth`, `/api/account`, `/api/schema` (read-only) and `/api/live/delivery` — **no documented REST for creating domains, accounts or DKIM keys** **[PRIMARY]**. Before any UI design: stand up v0.16 in a scratch namespace and establish empirically whether domain/account/app-password/DKIM provisioning is reachable via (a) an undocumented REST surface the web admin itself calls, (b) the CLI via `kubectl exec`, (c) direct writes to the settings store, or (d) nothing. **If the answer is (d), reconsider Mailu (§2.3).**

**Q2 — Where does outbound mail physically leave from?**
Three options: (a) **relay through a provider** — recommended, no PTR needed, fastest to production; (b) **egress via hypatia** — real PTR, but requires confirming Hetzner's port-25 status for this account, deciding how a pod's egress is pinned to cp4 without pinning its *storage* there, and accepting the 15 ms link; (c) **direct from the KPN line** — egress 25 works **[MEASURED]** but FCrDNS never will. This is a business decision about acceptable delivery risk, not a technical one.

**Q3 — Is inbound port 25 actually reachable from the internet today?**
**[UNVERIFIED]** — I tested egress only. Five-minute test from an external host against 203.0.113.10:25. If the answer is no, the entire inbound design changes and MX cannot point home.

**Q4 — Is 203.0.113.10 on the Spamhaus PBL (and anything else)?**
**[UNVERIFIED]** — Spamhaus refused my queries from a public resolver; the control returned the same refusal code, so the result is meaningless. Check via Spamhaus's web lookup or a DQS key. Also check 162.55.99.90. This directly determines whether Q2(c) is even conceivable.

**Q5 — One Cloudflare account or two?**
`infraweaver.net` is on the `adam`/`shaz` nameserver pair; `infraweaver.cloud` and `example.com` are on `adrian`/`tim` **[MEASURED]**. That is the signature of two accounts. Determines whether the DNS automation needs one token or several, and how tokens are scoped. **Scope every token to specific zones with Zone:DNS:Edit only** — a token that can edit `example.com` can break the operator's personal mail and the platform's SSO in one call.

**Q6 — Who owns the DNS writes: Stalwart, or the console addon?**
Stalwart's built-in automatic DNS management is the reason to choose it (§2.2). But it means a component inside a PVC holds a Cloudflare credential and writes to production zones on its own schedule — invisible to git, invisible to ArgoCD, and racing ExternalDNS if the domain filter ever widens. The alternative is the console addon computing the record set and writing it, with Stalwart's DNS management disabled — more code, but a plan/preview/apply flow with an audit trail, matching the staged-runner pattern this repo already landed for updates. **Whichever wins, exactly one writer per zone.**

**Q7 — What does "add a domain" mean for a domain that already has mail?**
`infraweaver.cloud` has `p=reject` and an SPF pointing at Hostnet **[MEASURED]**. Naively "setting all the correct DNS" would either clobber a live SPF or publish a source that DMARC rejects. The flow needs a **read-first plan/diff/confirm** step that classifies every existing record as keep / merge / replace, and refuses to proceed on an unrecognised MX without explicit confirmation. Design the destructive case first.

**Q8 — Single-tenant with many domains, or eventually Enterprise?**
Community is explicitly single-tenant-unlimited-domains; per-tenant quotas and isolation are Enterprise **[PRIMARY]**. If the roadmap is "agency clients each get an isolated compartment", that is a licence purchase. Decide now — it changes the data model.

**Q9 — Does Stalwart hot-reload rotated TLS certs from disk?**
**[UNVERIFIED]** (§3.6). If not, cert-manager renewal silently serves an expired cert until a restart. Needs a test and, if negative, a reload mechanism.

**Q10 — Does RocksDB on Longhorn perform acceptably, and does it survive a crash-consistent snapshot?**
**[UNVERIFIED]** (§3.5). Stalwart's docs are silent on network filesystems and on unclean-shutdown recovery. Measure latency, then hard-kill the pod mid-write and restore from a Longhorn snapshot. If RocksDB does not survive that, backup track 1 is not a backup.

**Q11 — Does the MetalLB speaker stay on cp4?**
`sites/hypatia.yaml` says `metallb_speaker: exclude`; the speaker is running **[MEASURED]**. A mail VIP announced from Falkenstein across the stretched VLAN is a specific and bad failure. Resolve the drift deliberately — this repo's most expensive recent incident was a scheduling intent *"written down in eight places and bound in none of them"*.

**Q12 — What is the upgrade policy for a weekly-release mail server?**
Twelve releases in twelve weeks **[MEASURED]**. Pin-and-forget accumulates CVEs; auto-update risks an unattended schema migration on a mail store. Proposal to evaluate: pin the minor, watch the security advisory feed, and run upgrades through the staged runner (plan → preview → gated waves, state in a ConfigMap) that already exists in this repo.

**Q13 — What is the retention and quota policy?**
Mail grows without bound. Per-account quota, per-domain quota, retention window, and what happens when one is hit (reject with 5xx? defer with 4xx? alert only?) are product decisions with legal and GDPR implications — and `docs/compliance/logging-and-retention-policy.md` already exists and will need to cover this.

**Q14 — Where does the addon's own control-plane state live?**
Domains, mailboxes, app passwords, DNS plans and relay config. Inside Stalwart (single source of truth, but opaque to git)? In the console's store (auditable, but now two sources that can drift)? Both, with reconciliation (the honest answer, and the most work)? This determines whether the addon page is a *view* of Stalwart or a *controller* over it.

---

## Appendix — commands used, for re-verification

```bash
export KUBECONFIG=~/.kube/config-platform-productie

# Cluster shape
kubectl get nodes -o wide --show-labels
kubectl get svc -A --field-selector spec.type=LoadBalancer -o wide
kubectl get ipaddresspools.metallb.io -A -o yaml
kubectl -n metallb-system get pods -o wide | grep speaker
kubectl -n traefik get deploy -o yaml | grep -E '^\s+- "?--'
kubectl -n traefik get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}'
kubectl get sc && kubectl get clusterissuers
kubectl -n external-dns get deploy -o yaml | grep -E '^\s+- --'
kubectl get cpol
kubectl get cpol generate-default-deny-cnp -o yaml
kubectl get ciliumnetworkpolicies -A
kubectl get ciliumclusterwidenetworkpolicies          # → none
kubectl -n longhorn-system get nodes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,ALLOWSCHED:.spec.allowScheduling
kubectl -n velero get schedules

# DNS / reputation ground truth
dig +short -x 203.0.113.10                            # 84-82-69-110.fixed.kpn.net.
dig +short -x 162.55.99.90                            # static.90.99.55.162.clients.your-server.de.
curl -s https://rdap.db.ripe.net/ip/203.0.113.10      # KPN B.V., NL
for d in infraweaver.net infraweaver.cloud example.com; do
  dig +short MX $d @1.1.1.1; dig +short TXT $d @1.1.1.1
  dig +short TXT _dmarc.$d @1.1.1.1; dig +short NS $d @1.1.1.1
done

# Outbound port 25 — MEASURED OPEN
exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25 && head -1 <&3
# → 220 mx.google.com ESMTP ... - gsmtp

# Upstream project facts
curl -s "https://api.github.com/repos/stalwartlabs/stalwart/releases?per_page=12"
curl -s "https://artifacthub.io/api/v1/packages/search?ts_query_web=stalwart&kind=0"
```

**Primary sources:** [stalwartlabs/stalwart](https://github.com/stalwartlabs/stalwart) · [Securing your server](https://stalw.art/docs/install/security/) · [Setting up DNS](https://stalw.art/docs/install/dns/) · [Network listeners](https://stalw.art/docs/server/listener) · [Kubernetes orchestration](https://stalw.art/docs/cluster/orchestration/kubernetes/) · [Proxy Protocol](https://stalw.art/docs/server/reverse-proxy/proxy-protocol/) · [Traefik](https://stalw.art/docs/server/reverse-proxy/traefik/) · [Docker install](https://stalw.art/docs/install/platform/docker/) · [Backup / Vandelay](https://stalw.art/docs/migration/import-export/backup/) · [Management API](https://stalw.art/docs/development/api/) · [Community vs Enterprise](https://stalw.art/compare/) · [Second security audit, 2025](https://stalw.art/blog/security-audit-2025/) · [GHSA-8jqj-qj5p-v5rr](https://github.com/stalwartlabs/stalwart/security/advisories/GHSA-8jqj-qj5p-v5rr) · [Mailu Helm charts](https://github.com/Mailu/helm-charts/) · [mailcow K8s request #7200](https://github.com/mailcow/mailcow-dockerized/issues/7200) · [Cloudflare email DNS records](https://developers.cloudflare.com/dns/manage-dns-records/how-to/email-records/) · [Cloudflare Spectrum](https://developers.cloudflare.com/spectrum/reference/configuration-options/)
