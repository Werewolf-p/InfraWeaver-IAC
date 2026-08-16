# Mailing addon — DNS ground truth

**Date:** 2026-08-16
**Phase:** RESEARCH ONLY. No DNS record was created, changed or deleted while producing this document. Every "measured" fact below came from a read: the Cloudflare API with the live platform token, `dig` against `1.1.1.1` and the zones' own authoritative nameservers, and read-only `kubectl`/`exec` probes from inside the running console pod.

**Requirement being researched (operator, verbatim):**
> "i want it super secure, as closed off as possible also dns wise if i add a domain to the mailing it will set all the correct mailing infromation dns wise… you may test with infraweaver.net and .cloud , i think those are in my cloudflare."

Both domains are confirmed in that Cloudflare account (measured — see §3.4). The single most important framing correction this research produces is in §1.0.

---

## 1. The complete record set for one mail domain

### 1.0 First: "all the correct mailing information" is two different record sets

The requirement assumes one answer. There are two, and picking the wrong one is the difference between "secure" and "broken".

| Domain intent | Correct record set | Why |
|---|---|---|
| **Mail domain** — sends and/or receives | MX + SPF + DKIM + DMARC + MTA-STS + TLS-RPT (§1.1–§1.7) | Authenticates real mail so it is deliverable and unspoofable |
| **Never-mail domain** — parked, web-only, or send-only-elsewhere | **Null MX + deny-all SPF + DMARC reject + DKIM revocation wildcard** (§1.10) | Strictly *more* closed-off than the full set, and impossible to get wrong |

`infraweaver.net` today has **zero DNS records of any type** (measured, §3.4). If it is not going to carry mailboxes, the "as closed off as possible" answer for it is §1.10, not §1.1–§1.7. The addon must ask this question and must not assume "add a domain to mailing" means "make it a mail server".

Throughout, the exact-example column uses `infraweaver.net`. Where a value depends on which mail provider backs the domain, the platform's incumbent is Microsoft 365 — the cluster's only outbound path today is a smarthost at `smtp-mail.outlook.com:587` authenticating as `example-owner@example.com` (`kubernetes/monitoring/kube-prometheus-stack/values.yaml:300-302`), and `example.com` carries both Microsoft 365 and Proton MX. **There is no mail server anywhere in the cluster** (measured: no Postfix/Mailu/Stalwart/maddy/mailcow/Dovecot/Rspamd manifest exists in either repo). So today the platform is a *sending client of a third-party provider*, never an MTA. That single fact removes DANE from scope (§1.8) and moves rDNS out of the addon's reach entirely (§1.9).

### 1.1 The record table

| # | Record | Purpose | Exact example for `infraweaver.net` | How to verify it is live and correct | What breaks if wrong or missing |
|---|---|---|---|---|---|
| 1 | **MX** | Names the hosts that accept inbound mail, in priority order. | `infraweaver.net. 3600 IN MX 10 infraweaver-net.mail.protection.outlook.com.` | `dig +short MX infraweaver.net` — every target must itself resolve to A/AAAA and must **not** be a CNAME (RFC 2181 §10.3). Compare the live set to the intended set as an unordered multiset of `(pref, host)`. | **Missing MX → senders fall back to the implicit MX, i.e. the apex A record (RFC 5321 §5.1).** This is live on `infraweaver.cloud` right now: it has an apex A but no MX, so the world tries to deliver mail to `188.114.96.0` — a Cloudflare proxy IP that does not answer on port 25. Mail to that domain fails today. A wrong MX silently routes all inbound mail to a stranger. |
| 2 | **SPF (TXT at apex)** | Authorizes which IPs may use this domain in the SMTP envelope sender. | `infraweaver.net. 3600 IN TXT "v=spf1 include:spf.protection.outlook.com -all"` | `dig +short TXT infraweaver.net` and select records starting `v=spf1`. **Count must be exactly 1.** Then recursively expand and count DNS-costing mechanisms (§1.2). | Two SPF records = `permerror` = SPF fails **entirely**, not "one of them wins". Over 10 lookups = `permerror`. `-all` published before every sender is enumerated = your own mail hard-rejected. |
| 3 | **DKIM (TXT at `<sel>._domainkey`)** | Publishes the *public* half of the key the MTA signs outbound mail with. | `selector1._domainkey.infraweaver.net. 3600 IN CNAME selector1-infraweaver-net._domainkey.<tenant>.onmicrosoft.com.` (hosted providers) — or a direct TXT: `s1._domainkey.infraweaver.net. IN TXT "v=DKIM1; k=rsa; p=MIIBIjANBgkq…"` | `dig +short TXT selector1._domainkey.infraweaver.net` must return a `v=DKIM1` record with a non-empty `p=`. **DNS alone proves nothing** — see §1.3 and §5.4. | Selector in DNS ≠ selector in the `DKIM-Signature: s=` header → verifier finds no key → DKIM fails on every message. Empty `p=` means *revoked*. With DMARC at `reject` and SPF unaligned, this rejects your own mail. |
| 4 | **DMARC (TXT at `_dmarc`)** | Ties SPF/DKIM results to the visible `From:` header, states the policy, and requests reports. | `_dmarc.infraweaver.net. 3600 IN TXT "v=DMARC1; p=none; sp=none; adkim=s; aspf=s; fo=1; rua=mailto:dmarc@infraweaver.net; ruf=mailto:dmarc@infraweaver.net"` | `dig +short TXT _dmarc.infraweaver.net`. Exactly one `v=DMARC1` record, `v=` first tag, `p=` second. **Must not be a CNAME.** If `rua`/`ruf` point off-domain, verify the external-destination authorization record (§1.4). | `p=reject` published before DKIM signs and SPF aligns = the domain's own mail is rejected by Gmail/Microsoft worldwide. No `rua` = the progression to `reject` is blind guesswork. Missing `sp=` means subdomains merely inherit `p` — explicit is safer. |
| 5 | **MTA-STS — TXT half** | Announces that a policy exists and versions it. | `_mta-sts.infraweaver.net. 3600 IN TXT "v=STSv1; id=20260816T120000Z;"` | `dig +short TXT _mta-sts.infraweaver.net`. | Senders re-fetch the policy **only when `id` changes**. Editing the policy file without bumping `id` is invisible for up to `max_age`. |
| 6 | **MTA-STS — HTTPS half** | The actual policy. **This is not a DNS record.** | `https://mta-sts.infraweaver.net/.well-known/mta-sts.txt`, `Content-Type: text/plain`, publicly-trusted cert for that exact hostname, body:<br>`version: STSv1`<br>`mode: enforce`<br>`mx: infraweaver-net.mail.protection.outlook.com`<br>`max_age: 604800` | Real HTTPS GET with certificate validation. Then assert the `mx:` patterns cover **every** live MX from row 1. | `mode: enforce` with an `mx:` list that misses a live MX → conforming senders **refuse to deliver**, and the bad policy stays cached for `max_age` (a week at 604800). A cert failure on the policy host has the same effect. This is the single most dangerous record in the set. |
| 7 | **TLS-RPT** | Asks senders to report TLS/MTA-STS/DANE failures. | `_smtp._tls.infraweaver.net. 3600 IN TXT "v=TLSRPTv1; rua=mailto:tlsrpt@infraweaver.net"` | `dig +short TXT _smtp._tls.infraweaver.net`. | Nothing breaks — it has zero enforcement effect. Its *absence* is what breaks you: it is the only way to see MTA-STS failures before they become silent lost mail. Publish it **before** MTA-STS, never after. |
| 8 | **DANE / TLSA** | Pins the MX server's certificate in DNS. | `_25._tcp.mx1.infraweaver.net. IN TLSA 3 1 1 <sha256 of SPKI>` | `delv` / a DNSSEC-validating query. Requires an authenticated chain. | **Useless without DNSSEC** — an unsigned TLSA is ignored by every conforming implementation. DNSSEC is `disabled` on all three zones (measured, §3.4). And a TLSA that survives a certificate rotation **hard-breaks inbound mail** from DANE-validating senders. See §1.8 — recommendation is *do not implement*. |
| 9 | **PTR / rDNS** | Maps the *sending IP* back to a hostname. | **Cannot be set from this zone.** Lives in `<octets>.in-addr.arpa`, delegated by whoever owns the IP block. | `dig -x <sending-ip>`, then forward-confirm: the PTR target's A record must return the same IP (FCrDNS). | Missing or non-forward-confirming PTR → many receivers reject or heavily penalize. Not the addon's problem *today* because the platform sends via a smarthost whose PTR is the provider's. See §1.9. |
| 10 | **Autodiscover / autoconfig** | Lets mail clients self-configure. | `autodiscover.infraweaver.net. IN CNAME autodiscover.outlook.com.` (DNS-only)<br>`_autodiscover._tcp.infraweaver.net. IN SRV 0 0 443 autodiscover.outlook.com.`<br>Thunderbird: `autoconfig.infraweaver.net` A/CNAME serving `/mail/config-v1.1.xml`<br>RFC 6186: `_imaps._tcp`, `_submissions._tcp` SRV | `dig +short CNAME autodiscover.infraweaver.net`; assert `proxied=false` via the Cloudflare API. | Clients fall back to manual setup (annoying, not fatal). **But**: Outlook POSTs credentials to whatever `autodiscover.<domain>` resolves to. If it is covered by a proxied wildcard or points at an unintended host, this is a credential-disclosure path, not a UX bug. It is covered by a proxied wildcard on `infraweaver.cloud` today (measured, §3.5). |
| 11 | **CAA** | Restricts which CAs may issue certificates for the domain. | `infraweaver.net. IN CAA 0 issue "letsencrypt.org"`<br>`infraweaver.net. IN CAA 0 iodef "mailto:security@infraweaver.net"` | `dig +short CAA infraweaver.net`. | No CAA on any zone today (measured) — **any CA in the world may issue**. But a CAA that is too narrow breaks the MTA-STS policy host's certificate, and with `mode: enforce` cached, that stops inbound mail. See §3.8 for the specific trap. |
| 12 | **BIMI** *(optional)* | Displays a brand logo in supporting clients. | `default._bimi.infraweaver.net. IN TXT "v=BIMI1; l=https://…/logo.svg; a=https://…/vmc.pem"` | `dig +short TXT default._bimi.infraweaver.net`. | Nothing breaks. Requires DMARC at `quarantine`/`reject` minimum. `example.com` has a BIMI record with **no `a=` (no VMC)**, so Gmail will not render it — cosmetic, but it is currently a record that does nothing. |

### 1.2 SPF in detail — the ten-lookup limit and why SPF alone is not enough

**Syntax.** One TXT record at the apex, beginning `v=spf1`, ending in an `all` qualifier. Mechanisms evaluate left to right; first match wins.

**The ten-lookup limit (RFC 7208 §4.6.4).** These terms each cost a DNS lookup: `include`, `a`, `mx`, `ptr`, `exists`, `redirect`. `ip4:`, `ip6:` and `all` cost **zero**. The limit is 10 for the *whole recursive evaluation*, not per record — an `include:` that itself contains two `include:`s costs 3. Exceeding it is `permerror`, and a `permerror` under DMARC counts as an SPF failure. Two subsidiary limits bite in practice: at most 10 MX names may be resolved by one `mx` mechanism, and at most **2 "void lookups"** (queries returning NXDOMAIN/NODATA) are allowed.

Measured expansion of the live `example.com` record —
`"v=spf1 a mx ip4:80.115.74.209 include:spf.protection.outlook.com include:_spf.protonmail.ch ~all"`:

| Term | Cost | Note |
|---|---|---|
| `a` | 1 | |
| `mx` | 1 | plus up to 10 MX-name resolutions |
| `ip4:80.115.74.209` | 0 | |
| `include:spf.protection.outlook.com` | 1 | expands to pure `ip4:`/`ip6:` + `-all` — terminates, measured |
| `include:_spf.protonmail.ch` | 1 + 1 | contains `include:_spf2.protonmail.ch` — measured |
| **Total** | **5** | Within budget, with 5 to spare. |

Measured expansion of the live `infraweaver.cloud` record — `"v=spf1 a mx include:_spf.hostnet.nl -all"`:

- `a` = 1, `mx` = 1, `include:_spf.hostnet.nl` = 1, and that record contains `include:_custspf.one.com` = 1. **Total 4.**
- But two of those are actively harmful here:
  - **`mx` matches nothing** — `infraweaver.cloud` has **no MX records**. That is a void lookup burning one of the two allowed.
  - **`a` authorizes Cloudflare's proxy IP range.** The apex A is Cloudflare-**proxied**, so `a` resolves publicly to `188.114.96.0` and `188.114.97.0` (measured). The SPF record therefore states that Cloudflare's anycast front-ends are authorized senders for `infraweaver.cloud`. `a`/`mx` on a proxied apex is an SPF weakness the addon must detect and refuse to reproduce.

**Why SPF alone is not enough — three independent reasons:**

1. **SPF checks the wrong From.** It validates the SMTP envelope sender (`MAIL FROM` / `Return-Path`), which the recipient never sees. An attacker sends with `MAIL FROM: <bounce@attacker.example>` and `From: ceo@infraweaver.net` — SPF passes for *attacker.example* and says nothing at all about the header the human reads. Only DMARC alignment binds the SPF result to the visible `From:`.
2. **SPF breaks on forwarding.** A mailing list or `.forward` re-sends from the forwarder's IP, which is not in your SPF. SPF fails on legitimate mail. DKIM survives forwarding (the signature travels with the message), which is exactly why both are needed.
3. **SPF has no integrity.** It authorizes an IP; it does not sign anything. A shared-hosting IP that is in your `include:` is in your `include:` for every other tenant on it too.

**`-all` vs `~all`.** `-all` (hardfail) instructs receivers to reject; `~all` (softfail) to accept-and-mark. For "as closed off as possible", `-all` is the destination. It must not be the starting point: publish `~all` first, read DMARC aggregate reports until every legitimate sending source is accounted for, then tighten. `?all` and `+all` must never be published; the addon should refuse both.

**Length.** A single DNS character-string is capped at 255 bytes. An SPF record that exceeds that must be split into multiple character-strings within one TXT RDATA (concatenated by the evaluator) — keeping the whole record well under ~450 bytes avoids the whole class of problem.

### 1.3 DKIM in detail

**Selector naming.** The selector is an arbitrary DNS label placed at `<selector>._domainkey.<domain>`. Its only hard requirement is that it **exactly matches the `s=` tag in the `DKIM-Signature:` header the MTA emits**. This is the coupling the addon cannot see: DNS holds the public half, the mail server holds the private half, and nothing in DNS reveals whether they are a pair. A perfectly valid `v=DKIM1` record with the wrong key verifies nothing. Convention: date- or purpose-stamped (`s2026a`, `mail202608`), never `default` — an un-rotatable name forces a flag-day rotation.

**Key size.** 1024-bit RSA is deprecated and treated as weak by several large receivers; **2048-bit RSA is the working recommendation**. Ed25519 (`k=ed25519`) produces a tiny record but is not universally supported — dual-signing with both an RSA and an Ed25519 selector is the compatible way to use it. A 2048-bit RSA `p=` value is roughly 392 base64 characters, which **exceeds the 255-byte DNS character-string limit** and must be published as multiple character-strings in one TXT record. *(Unverified in this account: no 2048-bit DKIM TXT exists in any of the seven zones today, so Cloudflare's exact API representation of a split TXT has not been observed here. The design phase must confirm whether the API accepts a single >255-char `content` string and splits it, or requires pre-split input.)*

**Rotation — the safe sequence.** Never edit a selector in place.
1. Publish the **new** selector's TXT/CNAME. Both selectors are now live.
2. Wait for propagation *and* for negative-cache expiry (30 min here — §5.2).
3. Switch the signing MTA to the new selector.
4. Wait out the in-flight window — messages already signed with the old key are still being verified by receivers, and deferred/queued mail can be days old. **7 days minimum**, and long enough to see a full DMARC aggregate cycle confirming `dkim=pass` on the new selector.
5. Only then delete the old selector's record — or, if the key is believed compromised, replace its `p=` with an empty value, which is the RFC 6376 revocation signal.

**Hosted providers publish CNAMEs, not TXTs.** `example.com` does exactly this (measured): `protonmail._domainkey`, `protonmail2._domainkey`, `protonmail3._domainkey` are all CNAMEs into Proton's `domains.proton.ch`. That is deliberate — it lets the provider rotate the underlying key without the customer touching their zone, and it means **the addon must support CNAME-shaped DKIM records, not only TXT**. It also means the addon must never "fix" a DKIM CNAME by replacing it with a TXT.

**A live gap worth recording:** `example.com` has three Proton DKIM selectors and **no Microsoft 365 selectors** (`selector1`/`selector2._domainkey` absent, measured), yet Microsoft 365 is an MX (priority 30) and is the platform's outbound smarthost. Mail sent through Microsoft 365 for that domain is therefore not DKIM-signed under `example.com`, and rests entirely on SPF alignment. Under the domain's live `p=quarantine`, a single forwarding hop breaks alignment and the message is quarantined. This is the exact failure mode the addon exists to prevent, present in production today.

### 1.4 DMARC in detail

**Syntax.** `v=DMARC1` must be the first tag and `p=` the second; a record that violates that ordering is ignored. `_dmarc.<domain>` must be a TXT, never a CNAME.

**Alignment** is the whole point. DMARC passes if **at least one** of SPF or DKIM passes **and** is *aligned* with the `From:` header domain:
- `aspf=r` / `adkim=r` (relaxed, the default): organizational-domain match — `mail.infraweaver.net` aligns with `infraweaver.net`.
- `aspf=s` / `adkim=s` (strict): exact FQDN match.
Strict is the "as closed off as possible" choice but will fail any provider that signs with a subdomain — verify against real reports before enabling.

**The progression.** `p=none` → `p=quarantine` → `p=reject`, with `pct=` as the ramp control (`pct=25` applies the policy to a quarter of failing mail). The progression is **driven by report data, never by elapsed time**. §2 turns this into gates.

**`rua` vs `ruf`.**
- `rua` — aggregate reports: daily gzipped XML, one row per sending source IP with SPF/DKIM/alignment pass-fail counts. **This is the instrument.** No PII. Every major receiver sends them. Without `rua` the progression is blind.
- `ruf` — failure/forensic reports: per-message, near-real-time, and contains message headers and often recipient addresses. Most large providers (Gmail, Microsoft) **do not send them at all** for privacy reasons. Set `fo=1` to request reports on any failure rather than only total failure. Treat `ruf` as a nice-to-have; a design that depends on it will receive nothing.

**External destination verification — the silent failure.** If `rua=mailto:dmarc@reports.example` points at a domain **different** from the one being reported on, RFC 7489 §7.1 requires the *receiving* domain to opt in by publishing:

```
infraweaver.net._report._dmarc.reports.example.  IN TXT  "v=DMARC1"
```

Without it, conforming reporters refuse to send and the operator silently receives nothing — while the console cheerfully reports "DMARC configured". If the addon ever centralizes reporting on one collector domain, **it must publish this record on the collector's zone for every monitored domain**, and its verifier must check for it.

**Subdomain policy `sp=`.** Absent, subdomains inherit `p`. Explicit `sp=reject` is the closed-off choice and matters more than it looks here: on a zone with a wildcard A (as `infraweaver.cloud` has), every conceivable subdomain resolves, so an attacker has an unlimited supply of plausible `@anything.infraweaver.cloud` sender domains. Inheritance covers them, but only if `p` itself is at `reject`; `sp=reject` covers them while the parent is still ramping.

**Live state, measured:**
- `infraweaver.cloud`: `"v=DMARC1; p=reject"` — **at maximum enforcement with no `rua`, no `ruf`, no `sp`, no alignment tags, and no DKIM anywhere in the zone.** Nothing legitimate can pass DMARC for this domain except SPF-aligned mail, and the operator has zero visibility into what is being rejected. This is enforcement without instrumentation: the worst of both worlds.
- `example.com`: `"v=DMARC1; p=quarantine"` — same shape, no `rua`.

### 1.5 MTA-STS — the record that is not only a record

MTA-STS has two halves and the DNS half is the trivial one.

**Half one, DNS:** `_mta-sts.<domain> IN TXT "v=STSv1; id=<opaque>"`. The `id` is a version token, conventionally a UTC timestamp. Senders cache the policy for `max_age` and **only re-fetch when `id` changes**. Bumping `id` is therefore mandatory on every policy edit, and is the addon's job — a human editing the file will forget.

**Half two, HTTPS:** `https://mta-sts.<domain>/.well-known/mta-sts.txt`, served over TLS with a publicly-trusted certificate **for that exact hostname**, `Content-Type: text/plain`, CRLF or LF line endings, body:

```
version: STSv1
mode: enforce
mx: infraweaver-net.mail.protection.outlook.com
max_age: 604800
```

`mx:` may be repeated and may use a single leading wildcard label (`mx: *.mail.protection.outlook.com`). **Every live MX must be covered by at least one `mx:` pattern**, or a sender in `enforce` mode will refuse to deliver to the uncovered host.

**This requires a web endpoint the platform must own.** That is feasible here — Traefik plus cert-manager plus the existing `letsencrypt-http` / `letsencrypt-dns` ClusterIssuers (`kubernetes/core/cert-manager/manifests/cluster-issuer.yaml`) already do exactly this shape of work for every other host. But it means "add a domain to the mailing addon" is **not a pure DNS operation**: it provisions an IngressRoute, a Certificate, and a served file, and the DNS `_mta-sts` TXT must not be published until that endpoint is proven to serve a valid policy over a valid cert.

**Failure modes, in order of severity:**
- `mode: enforce` + incomplete `mx:` list → **inbound mail refused**, cached for up to `max_age`.
- Policy host cert expires or fails validation → senders that already cached an `enforce` policy **refuse to fall back** → inbound mail refused for the remainder of `max_age`.
- Policy file unreachable (404, wrong content-type) with a cached `enforce` policy → same.
- `max_age: 604800` means every one of the above persists for a week. Start with a **short `max_age` (e.g. 86400)** and lengthen it only after a full reporting cycle is clean.

**Retirement.** You do not delete MTA-STS. You publish `mode: none` with a bumped `id`, wait out `max_age`, *then* remove the records. Deleting the TXT while `enforce` policies are cached is how a domain loses inbound mail with no visible cause.

**Proxied or not?** Unlike every other record here, the `mta-sts` A/CNAME **may** legitimately be Cloudflare-proxied — it is plain HTTPS and Cloudflare terminates with a valid certificate for the hostname. The trade-off is explicit: proxying puts Cloudflare in the trust path for the policy that governs the domain's transport security. The platform-native alternative (DNS-only → Traefik → cert-manager) keeps the policy on infrastructure the operator controls, which matches the "as closed off as possible" brief better. **This is a design decision, not a fact — flagged in §6.**

### 1.6 TLS-RPT

`_smtp._tls.<domain> IN TXT "v=TLSRPTv1; rua=mailto:tlsrpt@<domain>"` (an `https://` collector endpoint is also permitted).

Pure telemetry, zero enforcement risk, and the *only* mechanism that reports MTA-STS and DANE failures back to the domain owner. **Sequencing consequence: TLS-RPT must be published before MTA-STS `testing`, and MTA-STS must not reach `enforce` until TLS-RPT reports have been clean for a full cycle.** Publishing MTA-STS first means the first evidence of an enforce-mode failure is a user saying "nobody can email us".

### 1.7 Record-type summary for a full mail domain

```
infraweaver.net.                    MX    10 infraweaver-net.mail.protection.outlook.com.
infraweaver.net.                    TXT   "v=spf1 include:spf.protection.outlook.com -all"
selector1._domainkey.infraweaver.net. CNAME selector1-infraweaver-net._domainkey.<tenant>.onmicrosoft.com.
selector2._domainkey.infraweaver.net. CNAME selector2-infraweaver-net._domainkey.<tenant>.onmicrosoft.com.
_dmarc.infraweaver.net.             TXT   "v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s; fo=1; rua=mailto:dmarc@infraweaver.net"
_mta-sts.infraweaver.net.           TXT   "v=STSv1; id=20260816T120000Z;"
mta-sts.infraweaver.net.            A     <policy host>            (DNS-only or deliberately proxied — §1.5)
_smtp._tls.infraweaver.net.         TXT   "v=TLSRPTv1; rua=mailto:tlsrpt@infraweaver.net"
autodiscover.infraweaver.net.       CNAME autodiscover.outlook.com.   (DNS-only, MUST NOT be proxied)
infraweaver.net.                    CAA   0 issue "letsencrypt.org"
infraweaver.net.                    CAA   0 iodef "mailto:security@infraweaver.net"
```

### 1.8 DANE/TLSA — verdict: do not implement

TLSA records pin the MX server's certificate (or its SPKI) in DNS. The security value comes **entirely** from DNSSEC: without a signed chain, a TLSA record is unauthenticated data that an attacker can strip or forge, and every conforming implementation therefore ignores it.

- **DNSSEC is `disabled` on `infraweaver.net`, `infraweaver.cloud` and `example.com`** (measured via the Cloudflare DNSSEC API; no `DS` records at any parent). Enabling it is a Cloudflare one-click plus a DS record **at the registrar**, which is outside this token's and this platform's reach.
- Even with DNSSEC, DANE pins a certificate the platform does not control. The MX here is Microsoft 365 / Proton. Their certificate rotation is theirs; a stale TLSA after their rotation **hard-breaks inbound mail** from every DANE-validating sender (which in the .nl/.de ecosystem is a large fraction, and every Postfix configured with `smtp_tls_security_level = dane`).
- MTA-STS is the correct tool for provider-hosted MX precisely because it validates against the public WebPKI rather than pinning a key.

**Recommendation:** MTA-STS, not DANE. Revisit only if the platform ever runs its own MTA *and* the zone is DNSSEC-signed *and* the addon owns the MX certificate lifecycle end to end. The addon should not offer a TLSA button.

### 1.9 PTR / rDNS — why it cannot come from the domain's zone

Reverse DNS is not stored in the domain's zone at all. `203.0.113.10` resolves through `110.69.82.84.in-addr.arpa`, a name in the `in-addr.arpa` tree that is delegated from IANA → RIR → the **holder of the IP block**. For the platform that is the ISP on `203.0.113.10` and Hetzner on the `hypatia` host. Cloudflare has no authority there, this token has no authority there, and **no amount of correct configuration in `infraweaver.net` can produce a PTR record**. The addon must surface this as an out-of-band checklist item, never as something it can fix.

It matters when — and only when — the platform sends mail from its own IP. Today it does not: outbound goes through `smtp-mail.outlook.com:587`, so the PTR that receivers see is Microsoft's and is already correct. The relevant check is **FCrDNS**: `dig -x <ip>` → hostname → `dig A <hostname>` must return the original IP. A PTR that does not forward-confirm is treated as worse than none by several large receivers.

### 1.10 The "never-mail domain" record set — the genuinely most closed-off configuration

For a domain that will not send or receive mail — which is the likely truth for `infraweaver.net`, an empty zone today — the maximally-closed configuration is not the full mail set. It is:

```
infraweaver.net.                     MX   0 .                                  ; RFC 7505 null MX
infraweaver.net.                     TXT  "v=spf1 -all"
_dmarc.infraweaver.net.              TXT  "v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s; rua=mailto:dmarc@<collector>"
*._domainkey.infraweaver.net.        TXT  "v=DKIM1; p="                        ; wildcard revocation
```

- **Null MX (`MX 0 .`)** tells senders the domain accepts no mail, so they fail *immediately and permanently* rather than retrying for days — and, critically, it **suppresses the implicit-MX fallback to the apex A record** that is currently misdirecting mail for `infraweaver.cloud`.
- `v=spf1 -all` authorizes nothing.
- `p=reject; sp=reject` with strict alignment rejects every spoof attempt at the domain and every subdomain.
- The `*._domainkey` wildcard with an empty `p=` is the RFC 6376 revocation signal for *any* selector, denying an attacker who somehow publishes a key.

This set has no ordering hazard — none of it can break mail that does not exist — so it can be applied in one transaction. **The addon should offer it as a first-class mode**, and should probably default to it for a domain with no MX and no mailbox intent.

---

## 2. The safe rollout order

The core hazard: **every record in this set is safe on its own; the danger is entirely in the order.** `p=reject` before DKIM signs correctly is the canonical example, and MTA-STS `enforce` before the policy host is proven is the more severe one because its blast radius is *inbound* mail and it persists for `max_age` after the mistake is noticed.

The organizing principle: **publish the observability before publishing the enforcement.** Every tightening step must be gated on evidence produced by a step that came earlier.

### Phase 0 — Inventory and claim (writes: none)

Read every existing record in the zone. Classify each as: platform-owned, ExternalDNS-owned (§4), or **pre-existing operator-owned**. Compute the full diff the addon *would* apply and present it for approval. Nothing is written.

**Refuse to proceed if:** the zone already contains an SPF or DMARC record that the addon did not create and the operator has not explicitly approved replacing. `infraweaver.cloud` is exactly this case — it has a hand-set SPF delegating to Hostnet and a hand-set `p=reject`. A naive "set all the correct mailing information" writer would overwrite both, cutting off Hostnet as an authorized sender.

### Phase 1 — Decide the domain's intent

Mail domain, or never-mail domain (§1.10)? If never-mail, apply §1.10 in one transaction and stop. Everything below is the mail-domain path.

### Phase 2 — Receive path (writes: MX)

Publish MX. **Verify before continuing:** every MX target resolves to A/AAAA, no MX target is a CNAME, and `proxied=false` on all of them (structurally guaranteed for MX — §3.6 — but assert it anyway).

**Refuse to continue until:** MX is live and resolvable from an independent resolver, not merely accepted by the API.

### Phase 3 — Telemetry first (writes: DMARC `p=none` with `rua`; TLS-RPT)

Publish `_dmarc` at **`p=none`** with a working `rua`, and `_smtp._tls`. Nothing is enforced. This phase exists solely to start the flow of evidence that gates every later phase.

**Refuse to continue until:** if `rua` is off-domain, the `<domain>._report._dmarc.<collector>` authorization record exists on the collector's zone (§1.4). Without it no reports arrive and every subsequent gate is unprovable.

### Phase 4 — Authentication (writes: SPF with `~all`; DKIM selectors)

Publish SPF ending `~all` — softfail, so an unenumerated sender is marked, not rejected. Publish the DKIM selector records.

**Refuse to publish SPF if:** more than one `v=spf1` record would exist at the apex; the recursive lookup count exceeds 10; the record uses `+all`; or it uses `a`/`mx` while the apex A is Cloudflare-proxied (§1.2 — that authorizes the CDN as a sender).

**Refuse to claim DKIM is "configured":** publishing a `v=DKIM1` record is not evidence that the MTA signs with it. This phase ends with records published and DKIM status explicitly **unproven**.

### Phase 5 — Prove it with evidence (writes: none)

Collect DMARC aggregate reports. This is the gate the whole design hangs on.

**Do not advance until, from `rua` data:**
- a minimum volume of messages has been observed (a handful over one day is not evidence — the design phase must pick the threshold, §6),
- **every** sending source seen in the reports is either a known-authorized source or has been explicitly dispositioned by the operator,
- DKIM pass rate from authorized sources is ~100% — this is the *only* real proof that the published selector matches the signing key,
- SPF alignment is passing from authorized sources.

**Refuse to advance if:** zero reports have been received. Zero reports means the instrument is broken, not that everything is fine. This distinction must be visible in the UI — "no failures observed" and "no data" must never render the same way.

### Phase 6 — Tighten SPF (writes: SPF `~all` → `-all`)

Only after Phase 5 shows every legitimate source enumerated. Re-verify; watch one more report cycle.

### Phase 7 — DMARC ramp (writes: `p=quarantine`, then `pct` ramp, then `p=reject; sp=reject`)

`p=none` → `p=quarantine pct=25` → `pct=100` → `p=reject; sp=reject`. Each step re-gated on a clean report cycle. Never skip `quarantine`: quarantine is recoverable by the recipient, reject is not.

**Refuse `p=reject` unless:** DKIM has been *proven* passing (Phase 5), SPF is at `-all` and passing, and at least one full aggregate-report cycle at `quarantine` showed no legitimate mail failing. **A published `p=reject` with no `rua` — the current live state of `infraweaver.cloud` — must be flagged by the addon as a misconfiguration, not accepted as "already done".**

### Phase 8 — Transport security (writes: `mta-sts` host + policy endpoint, then `_mta-sts` TXT)

1. Provision the policy host: IngressRoute, Certificate, and the served `/.well-known/mta-sts.txt` — with `mode: testing` and a **short `max_age`**.
2. **Verify by real HTTPS GET with certificate validation**, from outside the cluster if at all possible.
3. Only then publish the `_mta-sts` TXT.
4. Sit in `testing` for a full TLS-RPT cycle.
5. Flip to `mode: enforce` (bump `id`), still short `max_age`.
6. Lengthen `max_age` only after enforce has been clean for a cycle.

**Refuse to publish `_mta-sts` TXT unless:** the HTTPS endpoint currently returns a valid policy over a valid certificate, **and** the policy's `mx:` patterns cover every live MX from Phase 2. Re-check this invariant on every MX change forever — an MX added later that the policy does not cover breaks inbound mail from enforcing senders.

### Phase 9 — CAA (writes: CAA)

Publish CAA **including every CA the platform's own certificate paths depend on** — see the trap in §3.8. Verify that a certificate renewal still succeeds before considering this done.

### Never — DANE/TLSA

§1.8.

### Summary of hard refusals

| The addon must refuse to… | Until… |
|---|---|
| Publish `p=quarantine` or `p=reject` | DKIM is proven passing via `rua` data, not merely published |
| Publish SPF `-all` | every sending source in `rua` is enumerated and authorized |
| Publish a second `v=spf1` record at an apex | never — it is always a permerror |
| Publish SPF with `+all`, or `a`/`mx` against a proxied apex | never |
| Publish `_mta-sts` TXT | the HTTPS policy endpoint validates and covers every live MX |
| Set MTA-STS `mode: enforce` | a full TLS-RPT cycle in `testing` is clean |
| Delete MTA-STS records | `mode: none` has been published and `max_age` has elapsed |
| Delete a DKIM selector | the replacement is proven passing and the in-flight window (≥7 days) has passed |
| Overwrite a pre-existing SPF/DMARC/MX it did not create | the operator explicitly approves the specific diff |
| Report a domain "configured" | live resolution from an independent resolver confirms it — §5 |
| Publish CAA | the platform's own issuance paths are represented in it |

---

## 3. Cloudflare specifics

### 3.1 API and auth model

Base: `https://api.cloudflare.com/client/v4`. Auth: `Authorization: Bearer <token>` (API **Tokens**, scoped). The legacy `X-Auth-Key` + `X-Auth-Email` global-key model must not be used — it is account-wide and unscopable.

Every response is a uniform envelope: `{ success, result, errors[], messages[], result_info }`. **`success: false` can accompany HTTP 200**, so status-code-only error handling is wrong. The existing `cfRequest` in `apps/infraweaver-console/src/lib/cloudflare.ts:92-100` already checks both — that is the pattern to keep.

Relevant endpoints (all zone-scoped):
- `GET /zones` — list; paginated
- `GET /zones/{zone_id}/dns_records` — list; supports `type=`, `name=`, `content=`, `per_page`, `page`
- `GET /zones/{zone_id}/dns_records/{id}`
- `POST /zones/{zone_id}/dns_records` — create
- `PATCH /zones/{zone_id}/dns_records/{id}` — partial update
- `PUT /zones/{zone_id}/dns_records/{id}` — full replace
- `DELETE /zones/{zone_id}/dns_records/{id}`
- `POST /zones/{zone_id}/dns_records/batch` — atomic multi-op (`deletes`/`patches`/`puts`/`posts`) *(unverified here — not exercised, because exercising it means writing)*

### 3.2 Token scopes — narrowest that works

For the mailing addon the minimum is:

| Permission | Why |
|---|---|
| **Zone → DNS → Edit** | create/read/update/delete records. Cloudflare's `DNS:Edit` implies read. |
| **Zone → Zone → Read** | resolve zone name ↔ zone id (`resolveZoneId` needs the zone list) |

Scope it **to the specific zones** the mailing addon manages, via the token's zone-resource selector — not "All zones from an account".

Optional, only if the corresponding feature is built: `Zone → DNSSEC → Read` (to *report* DNSSEC status), `Zone → SSL and Certificates` (only if the addon manages the MTA-STS certificate through Cloudflare rather than cert-manager).

**Never grant** Account-level permissions, `Zone → Zone Settings → Edit`, or `User → API Tokens`.

**Measured scope of the token actually in use today** (probe results, HTTP status per endpoint):

| Endpoint | Result |
|---|---|
| `GET /zones` | **200** — returns **7 zones** |
| `GET /zones/{id}/dns_records` | **200** |
| `GET /zones/{id}/dnssec` | **200** |
| `GET /accounts` | **200** |
| `GET /zones/{id}/settings/ssl` | **403** |
| `GET /zones/{id}/email/routing` | **403** |
| `GET /user/tokens` | **403** |

So the live token is roughly *DNS edit + zone read across the whole account*, not scoped to a zone. See §4.1 — this is a finding, not a recommendation.

### 3.3 Rate limits and idempotency

**Rate limit, measured from live response headers:**
```
ratelimit-policy: "default";q=1200;w=300
ratelimit: "default";r=1199;t=1
```
1200 requests per 300-second window, with remaining count returned on every response. That is generous for this workload — a full mail record set is ~10 writes and a verification pass is a handful of reads — but a naive per-domain reconcile loop across many domains can reach it. The addon should read `ratelimit` from responses and back off on `429` honouring `Retry-After`, rather than assuming the budget.

**Idempotency: there is none at the API level.** Cloudflare's DNS API provides no idempotency key. `POST` creates unconditionally; a retried `POST` after a timeout-but-succeeded creates a **duplicate**. For TXT records this is not cosmetic — **two `v=spf1` records is a permanent SPF permerror**, and two `_dmarc` records means DMARC is ignored entirely.

Idempotency must therefore be built in the addon, as **read-diff-write**, never blind-write:
1. `GET` records filtered by `type` and `name`.
2. Classify: absent / present-and-correct / present-and-wrong / present-and-duplicated.
3. Absent → `POST`. Wrong → `PATCH` the existing id (never delete-then-create for policy records — the gap between the two is a window with no SPF/DMARC at all). Duplicated → surface for operator decision; do not silently pick one.
4. Correct → **write nothing**.

The codebase already contains the right precedent for this and the reasoning behind it: `addons/gamehub/lib/game-srv-reconcile.ts` explicitly probes before writing because `upsertSrvRecord` is delete-then-create and blind re-publishing would leave a window where the record does not exist. The same reasoning applies with far higher stakes to SPF and DMARC.

### 3.4 Live state of `infraweaver.net` and `infraweaver.cloud` (measured 2026-08-16)

All seven zones visible to the token, all in account `example-owner@gmail.com's Account`, all Free plan, all `active`:

| Zone | Zone ID | DNSSEC |
|---|---|---|
| `infraweaver.cloud` | `99bf6f8e2657371fc52c6662f7e755f4` | disabled |
| `infraweaver.net` | `d0e4ab31aeed08d52e3aa55e6fb4fbfd` | disabled |
| `infraweaver.nl` | `9b29b2352579a75237249eb6b20c42bf` | — |
| `example.com` | `00000000000000000000000000000000` | disabled |
| `waterdance.nl` | `fcc0dd04186df4d102291c02f9ad1334` | — |
| `yonavaarwater.nl` | `843e6325f4450bbcb63b16d6dc46edde` | — |
| `zonnevaarwater.nl` | `db24ce06187f3a5008a791fca34fc0bf` | — |

Note `infraweaver.nl` also exists — a third InfraWeaver domain the brief did not mention.

**`infraweaver.net` — 0 records. Completely empty zone.**
Delegation is live (`adam.ns.cloudflare.com`, `shaz.ns.cloudflare.com`) and the zone answers, but contains nothing: no A, no MX, no TXT, no CAA. Every name under it returns **NXDOMAIN**. This is a clean greenfield and the ideal test domain — **and it currently has no mail protection at all**, meaning anyone can spoof `@infraweaver.net` today with nothing to stop them. (`infraweaver.cloud`/`example.com` sit on `adrian`/`tim` — different NS pairs, same account; that is normal Cloudflare per-zone assignment and is **not** evidence of a second account.)

**`infraweaver.cloud` — 6 records, and it has hand-set mail policy a naive writer would destroy:**

| Type | Name | Proxied | Content |
|---|---|---|---|
| A | `*.infraweaver.cloud` | **true** | `91.184.0.200` |
| A | `infraweaver.cloud` | **true** | `91.184.0.200` |
| AAAA | `infraweaver.cloud` | **true** | `2a02:2268:1:0:f816:3eff:fe7b:63c6` |
| CNAME | `www.infraweaver.cloud` | true | `infraweaver.cloud` |
| TXT | `_dmarc.infraweaver.cloud` | false | `"v=DMARC1; p=reject"` |
| TXT | `infraweaver.cloud` | false | `"v=spf1 a mx include:_spf.hostnet.nl -all"` |

Four independent problems, all live:
1. **No MX.** The domain cannot receive mail, and the implicit-MX fallback points senders at the proxied apex A — measured public resolution `188.114.96.0` / `188.114.97.0`, Cloudflare anycast, which does not answer SMTP.
2. **SPF `a` authorizes Cloudflare's proxy range** because the apex A is proxied (§1.2). `mx` matches nothing and burns a void lookup.
3. **`p=reject` with no `rua`.** Maximum enforcement, zero visibility, no DKIM in the zone.
4. **The SPF delegates to Hostnet** (`_spf.hostnet.nl` → `91.184.8.0/24`, `91.184.19.0/24`, `include:_custspf.one.com`). This is a real, deliberate, operator-set authorization for a third-party host. **An addon that "sets all the correct mailing information" by writing its own SPF would silently de-authorize Hostnet.**

**`example.com`** (37 records) is the mature reference and is documented inline in §1.3 / §1.4 — three MX across two providers, Proton DKIM CNAMEs, no Microsoft 365 DKIM, `p=quarantine` with no `rua`, a BIMI record with no VMC, and no MTA-STS/TLS-RPT/CAA/DNSSEC.

**Across all inspected zones: no MTA-STS, no TLS-RPT, no CAA, no DNSSEC anywhere.**

### 3.5 The wildcard trap — measured, and it changes how verification must work

`infraweaver.cloud` has a **proxied wildcard** `*.infraweaver.cloud → 91.184.0.200`. Measured consequences:

| Query | Result |
|---|---|
| `A mta-sts.infraweaver.cloud` | `188.114.96.0`, `188.114.97.0` — **already resolves, proxied, to the wrong host** |
| `A autodiscover.infraweaver.cloud` | resolves to the wildcard — Outlook's credential-bearing probe hits Hostnet |
| `A selector1._domainkey.infraweaver.cloud` | resolves to the wildcard |
| `A nope.infraweaver.cloud` | **NOERROR** (not NXDOMAIN) |
| `A nope.infraweaver.net` | **NXDOMAIN** |
| `TXT _dmarc.infraweaver.cloud` | **NOERROR** with an answer |

Two consequences the design must absorb:

1. **Rcode cannot be used to decide "does this record exist".** On a wildcard zone every name is NOERROR; on an empty zone every name is NXDOMAIN. A verifier that treats NXDOMAIN as "absent" and NOERROR as "present" will report `.cloud` fully configured and `.net` fully broken, both wrongly. **Existence must be decided per record type on the presence of a matching answer**, treating NOERROR-with-empty-answer (NODATA) as absent — and, for correctness, on the record's *content*, not merely its presence.
2. **MTA-STS on a wildcard zone is pre-broken.** `mta-sts.infraweaver.cloud` already resolves to a proxied third-party origin that will not serve `/.well-known/mta-sts.txt`. Publishing the `_mta-sts` TXT without first creating an explicit, more-specific `mta-sts` record and a real endpoint means senders fetch a policy from Hostnet and get a 404. Combined with an `enforce` policy this is an inbound-mail outage. **An explicit record always beats a wildcard**, so the fix is to create the specific name — but the addon must know to do it, and must verify the endpoint rather than the DNS record.

### 3.6 Proxied vs DNS-only — confirmed, with a caveat that matters more

**Confirmed by measurement.** Cloudflare reports a `proxiable` flag per record. Grouped over the live `example.com` zone:

| Type | `proxiable` | any `proxied` | n |
|---|---|---|---|
| A | true | true | 7 |
| CNAME | true | true | 15 |
| **MX** | **false** | false | 3 |
| **SRV** | **false** | false | 1 |
| **TXT** | **false** | false | 11 |

So **MX, TXT and SRV can never be proxied** — Cloudflare's proxy is an HTTP/HTTPS reverse proxy on a fixed port set and has no representation for these types. SPF, DKIM, DMARC, MTA-STS-TXT and TLS-RPT are all TXT; MX is MX. **These are structurally safe.**

**The real risk is the record types that *are* proxiable**, because the Cloudflare dashboard defaults new A/CNAME records to proxied:
- `mail.<domain>`, `smtp.<domain>`, `imap.<domain>`, `mx1.<domain>` as A/CNAME → proxied means the name resolves to Cloudflare anycast, which does not answer 25/465/587/993. **Mail silently stops.** This is the classic orange-cloud mail outage.
- `autodiscover.<domain>` proxied → Outlook's credential-bearing probe is routed through the CDN to whatever origin answers.
- A **proxied apex A** poisons any SPF using `a` (§1.2) — live on `infraweaver.cloud`.
- A **proxied wildcard** silently covers every mail hostname (§3.5) — live on `infraweaver.cloud`.

**Rule for the addon: every mail-related A/CNAME it creates must be written with an explicit `proxied: false`, and its verifier must assert `proxied === false` on read for every such record — including ones it did not create.** Omitting `proxied` from the request body is not sufficient; be explicit. (The existing `createDnsRecord` at `lib/cloudflare.ts:213-232` only sends `proxied` when the caller passes a boolean, so the mailing addon must always pass it.)

The `mta-sts` host is the single deliberate exception (§1.5) and must be a conscious, recorded choice.

### 3.7 Not clobbering the operator's hand-set records

The problem is concrete: `infraweaver.cloud` holds an SPF that delegates to Hostnet and a `p=reject` DMARC, neither created by this platform.

Cloudflare gives no ownership metadata on DNS records. What is available:
- `created_on` / `modified_on` timestamps (already surfaced by `CloudflareDnsRecord`).
- ExternalDNS's TXT registry — but only for records ExternalDNS created (§4.2), and it does not create mail records.
- Nothing else. **Ownership must be tracked by the addon itself.**

Design requirements this produces:
1. **Read-diff-approve before any write on a zone the addon has not previously claimed.** Phase 0 (§2) is mandatory, not optional.
2. **Maintain an explicit ownership ledger** — which `(zone, name, type, content-hash)` tuples the addon created — so a later reconcile can distinguish "drifted from what I wrote" (safe to correct) from "the operator changed this deliberately" (must ask) from "this predates me" (never touch without approval).
3. **Never blind-`PUT`/`POST` a policy record on a zone that already has one of that shape.**
4. **Reuse the existing safety layer rather than writing a second one.** `apps/infraweaver-console/src/lib/dns.ts` already contains a battle-tested *allowlist* (`explainUndeletableRecordShape`) that structurally refuses to delete the apex, wildcards, every underscore label (`_dmarc`, `*._domainkey`, `_mta-sts`, `_smtp._tls`), every mail-shaped hostname, all non-allowlisted types including MX, and any TXT matching `v=spf1|v=DMARC1|v=DKIM1|v=BIMI1|*-site-verification`. It was written after a type-blind teardown deleted a root domain's MX and SPF. **The mailing addon is the first component that legitimately needs to write those exact shapes** — which means it must not weaken that allowlist. It should get a separate, narrowly-scoped, ledger-backed write path, and the delete allowlist must stay exactly as strict as it is for everything else.

### 3.8 CAA and certificate issuance — a real trap

No CAA record exists on any inspected zone, so today **any CA may issue for these domains**. Adding CAA is a genuine "closed off" improvement and belongs in the set.

The trap: CAA is enforced at issuance time for **every** certificate on the domain, and the platform has more than one issuance path:
- **cert-manager**, via `letsencrypt-http` (HTTP-01) and `letsencrypt-dns` (DNS-01 through Cloudflare) — `kubernetes/core/cert-manager/manifests/cluster-issuer.yaml`. Needs `issue "letsencrypt.org"`.
- **Cloudflare Universal SSL**, which serves every proxied hostname — and `infraweaver.cloud`'s apex, `www` and wildcard are all proxied. Cloudflare's edge certificates are issued by CAs that are **not** Let's Encrypt (Google Trust Services and others, and Cloudflare's choice changes over time). *Unverified: the exact CA set Cloudflare uses for Universal SSL on this account today was not checked — the token returns 403 on the SSL/settings endpoints (§3.2).*

**A CAA record of `0 issue "letsencrypt.org"` alone can therefore break Cloudflare Universal SSL renewal on any proxied hostname**, which for `infraweaver.cloud` is the website itself. And if the MTA-STS policy host's certificate is the one that fails, cached `enforce` policies turn that into an inbound-mail outage.

Requirements: enumerate every CA in every issuance path *before* publishing CAA; include `issuewild` deliberately (a wildcard cert needs it); add `iodef` for violation reports; and treat "a certificate renewal succeeded after CAA was published" as the verification step, not "the CAA record resolves".

### 3.9 Cloudflare Email Routing

Cloudflare offers Email Routing, which auto-provisions its own MX records and would fight anything the addon writes. The current token **cannot read its state** (`GET /zones/{id}/email/routing` → **403**, measured). Since neither `infraweaver.net` nor `infraweaver.cloud` has any MX at all, it is almost certainly not enabled — but this is inferred, not measured. **The design phase must either grant the token read access to this endpoint or accept that the addon cannot detect an Email-Routing-managed zone.**

---

## 4. What this platform already does with DNS

### 4.1 Credentials — one token, everywhere, account-wide

Measured: the Cloudflare token in `external-dns` and the Cloudflare token in the console's secret are **byte-identical**, and it sees **all 7 zones in the account**.

Storage path: OpenBao → External Secrets Operator → Kubernetes Secret → env var. Two OpenBao paths exist and diverge:

| Consumer | OpenBao path | K8s secret | Env/ref |
|---|---|---|---|
| ExternalDNS | `secret/platform/cloudflare#CF_API_TOKEN` | `cloudflare-api-token` (ns `external-dns`) | `CF_API_TOKEN` |
| cert-manager | `secret/platform/dns-provider#cloudflare-api-token` | `dns-provider-credentials` (ns `cert-manager`) | ClusterIssuer `apiTokenSecretRef` |
| Console | `secret/platform/infraweaver-console#cloudflare-api-token` | `infraweaver-console-secret` | `CLOUDFLARE_API_TOKEN` |

`kubernetes/platform/external-dns/manifests/externalsecret.yaml`, `kubernetes/core/cert-manager/manifests/external-secret-dns.yaml`, `kubernetes/catalog/infraweaver-console/base/{externalsecret,deployment}.yaml:363-372`.

**Finding.** One shared credential with account-wide DNS-edit rights is the platform's largest DNS blast radius, and the mailing addon is about to become the fourth consumer and the first one that deliberately writes MX/SPF/DKIM/DMARC. A compromise or a bug in any consumer can rewrite the mail records of all seven domains, including three (`waterdance.nl`, `yonavaarwater.nl`, `zonnevaarwater.nl`) that are client sites. **Recommendation: mint a separate, zone-scoped `DNS:Edit` + `Zone:Read` token for the mailing addon, at a distinct OpenBao path, restricted to the zones enrolled in mailing.** That also gives the addon a natural enrollment boundary — a domain not in the token's scope cannot be touched at all.

### 4.2 Who owns records today

**ExternalDNS** is the only automated writer of *records* today (`kubernetes/platform/external-dns/values.yaml`):
- Sources: `traefik-proxy` + `service`. IngressRoutes are the source of truth.
- **Opt-in**: `--annotation-filter=external-dns.alpha.kubernetes.io/managed in (true)`.
- **`domainFilters: ["example.com"]` — hardcoded**, and the file documents *why*: Helm `valueFiles` bypass the ArgoCD envsubst CMP, so a `${BASE_DOMAIN}` placeholder reached the container literally and silently dropped every new record.
- `policy: upsert-only` — it never deletes. The file contains an extensive, still-open analysis of the preconditions for flipping to `sync`, including one blocker (`n8n.example.com`).
- Ownership registry: TXT records named `edns-<type>-<host>` carrying `heritage=external-dns` and `external-dns/owner=infraweaver-prod`.
- Reconcile interval: `2m`.

**The console** writes records directly via `lib/cloudflare.ts` for: DNS surface CRUD (`/api/dns`), game-server A and SRV records, and WordPress site provisioning/teardown.

**A shell script** (`scripts/deploy/ensure-cloudflare-dns.sh`) upserts the `*.int.<domain>` wildcard during full redeploys.

### 4.3 Would a new writer conflict with ExternalDNS?

**Not today, on these domains — for two independent reasons:**

1. **`domainFilters` is `example.com` only.** ExternalDNS is structurally blind to `infraweaver.net` and `infraweaver.cloud`. It cannot see, create, or delete anything there.
2. **Even on `example.com`, the namespaces do not overlap.** ExternalDNS publishes A/CNAME records for Host() rules on annotated IngressRoutes. It does not create MX, `_dmarc`, `*._domainkey`, `_mta-sts` or `_smtp._tls`, and with `policy: upsert-only` it deletes nothing at all.

**Where a conflict could appear later, and what protects against it:**
- If `domainFilters` is widened to include a mail domain **and** `policy` is flipped to `sync`, ExternalDNS's deletion pass is still confined to records carrying its own `edns-` ownership TXT with `owner=infraweaver-prod`. Mail records written by the addon would have no such TXT and are therefore **structurally invisible** to it. The `values.yaml` analysis confirms this was measured against the live zone on 2026-08-06.
- The genuine overlap is at the **apex**: ExternalDNS or the WordPress provisioner creating/replacing an apex A on a domain that is also a mail domain. The address record and the MX coexist fine, but two things bite: the teardown path, and SPF `a`. The teardown path is already guarded — `deleteAddressRecordsByName` and `deleteManagedHostRecords` call `assertNotZoneApex` and are type-scoped to A/AAAA/CNAME, after an earlier incident where a type-blind teardown deleted a root domain's MX and SPF. **The SPF `a` interaction is not guarded** and is live on `infraweaver.cloud` (§1.2).
- **New risk the addon introduces:** it is the first component that will create `mta-sts.<domain>` as an A/CNAME. That name is *mail-shaped* by `lib/dns.ts`'s `MAIL_EXACT_LABELS`, so the existing delete allowlist will refuse to remove it — correct for safety, but it means the addon's own teardown path needs its own deliberate, ledger-backed route. It must not be achieved by loosening the shared allowlist.

### 4.4 How zone ids are resolved today — the `CF_ZONE_ID` history

Both mechanisms coexist:

- **Static env default.** `CF_ZONE_ID` is injected into the console from `infraweaver-console-secret#cf-zone-id`. **Measured live value: `00000000000000000000000000000000` = `example.com`.** `requireZoneId()` (`lib/cloudflare.ts:80-84`) falls back to it whenever a caller passes no explicit zone.
- **Dynamic resolution.** `resolveZoneId(name)` (`lib/cloudflare.ts:163-170`) lists zones and picks the **longest zone name that is a suffix of the host**, so `blog.example.com` resolves to the `example.com` zone. `resolveZoneIdForHost()` is the best-effort variant returning `undefined`, and callers then fall back to the env default. `resolveZoneApex(zoneId)` reads the zone's own name from the zone list — deliberately, because Cloudflare's DNS-record responses no longer carry `zone_name` and the delete allowlist needs an apex it did not derive from the record being checked.
- The deploy script resolves the id at runtime from `GET /zones?name=${BASE_DOMAIN}`.

**Implication for the mailing addon:** `CF_ZONE_ID` points at `example.com`. Any code path that omits an explicit `zoneId` writes into `example.com` — the platform's real, live, production mail domain. **The mailing addon must never rely on the env default. Every call must pass an explicit `zoneId` resolved from the domain being configured, and the addon should assert that the resolved zone's apex equals the domain it was asked to configure before any write.** The "DNS fix hinged on `CF_ZONE_ID`" note from a prior session is the same hazard viewed from the other side: a silently-wrong default zone.

### 4.5 Conventions the addon should inherit

- **Opt-in over opt-out**, everywhere (ExternalDNS's annotation filter; the console's managed-name filters).
- **Allowlists, not denylists** — `lib/dns.ts` says so explicitly and gives the reason: a denylist only knows the disasters that already happened.
- **Probe before write** — `game-srv-reconcile.ts` exists solely because blind re-publishing creates a window where the record does not exist.
- **Reasons written for a human**, not error codes — `explainUndeletableRecordShape` returns prose naming the record and the rule.
- **`unknown` is never rendered as `empty`** — the console's design canon (`docs/design/INFRAWEAVER-STYLE.md`, S8). Decisive for §5: "no DMARC reports yet" must never render like "no failures".

---

## 5. Verification — proving it, not claiming it

### 5.1 "The API accepted it" ≠ "the world can resolve it"

A `200 { success: true }` from Cloudflare proves the record is in Cloudflare's *control plane*. Between that and a receiving MTA behaving correctly there are at least five independent gaps:

1. Propagation to Cloudflare's authoritative edge (fast, but not zero).
2. Recursive resolvers holding a **cached positive answer** for the old value until its TTL expires.
3. Recursive resolvers holding a **cached negative answer** — the expensive one, §5.2.
4. Semantic correctness — a syntactically valid record can be wrong (a DKIM key that is not the signing key; an MTA-STS policy missing an MX).
5. Behavioural correctness — whether real receivers actually pass the mail, which only DMARC and TLS-RPT reports can show.

**The addon must therefore have three distinct verification tiers**, and must never let a lower tier satisfy a higher one:

| Tier | Method | Proves | Latency |
|---|---|---|---|
| **A — Control plane** | Cloudflare `GET` after write | "I wrote what I intended, once, with no duplicate" | seconds |
| **B — Resolution** | Live DNS query through an independent resolver | "the world can resolve it" | seconds–30 min |
| **C — Behaviour** | DMARC `rua` + TLS-RPT reports; a round-trip test message | "real receivers accept and authenticate real mail" | hours–days |

Tier A is what most tools call "configured". Tiers B and C are what the operator's requirement actually asks for.

### 5.2 Propagation and negative caching — the concrete numbers here

**Measured SOA for all three zones:** `… 10000 2400 604800 1800`. The final field — the **SOA minimum, 1800 seconds — is the negative-cache TTL**. RFC 2308 caps negative caching at `min(SOA MINIMUM, SOA TTL)`.

Consequence, and it is the single most important verification fact in this document:

> **If anything queried `_dmarc.infraweaver.net` before the record existed — including the addon's own pre-flight check — that resolver will answer NXDOMAIN for up to 30 minutes after the record is created.**

So a verifier that writes a record and immediately checks it **through the same resolver it used for its pre-flight check** will report failure, and a naive design will then retry the write, creating a duplicate — which for SPF or DMARC is a permanent break (§3.3). Requirements:

- Treat "not yet visible" as a distinct state from "wrong". Never retry a *write* because a *read* failed.
- Expect up to **30 minutes** for a negative→positive transition; positive TTLs are shorter (Cloudflare `ttl: 1` = "auto" ≈ 300s, measured `TTL: 300` on the live `infraweaver.cloud` SPF answer).
- Prefer **not** doing a pre-flight query against the same public resolver used for verification; use the Cloudflare API (Tier A) for pre-flight existence checks, which has no cache at all.
- Query the zone's **authoritative nameservers** (`adam.ns.cloudflare.com` for `infraweaver.net`) to observe the true state immediately, and a **public recursive resolver** to observe what the world sees — and show both, because their disagreement *is* the propagation status.

**CoreDNS caveat.** The cluster's `kube-system` CoreDNS runs `cache 30` for non-`cluster.local` names, capping cached TTLs at 30s. That is favourable, but it only bounds *this cluster's* view; the 1800s negative cache still governs external resolvers.

### 5.3 Transport constraints — measured from inside the console pod

This is the hard constraint on how verification can be implemented, and it was measured from inside the running pod, not inferred from manifests:

| Target | Result |
|---|---|
| `smtp-mail.outlook.com:587` | **CONNECTED** |
| `api.cloudflare.com:443` | **CONNECTED** |
| `1.1.1.1:53` (TCP) | **TIMEOUT — blocked** |
| `mail.protonmail.ch:25` | **TIMEOUT — blocked** |
| DoH `https://cloudflare-dns.com/dns-query` | **WORKS** — returned the live `infraweaver.cloud` SPF |

The NetworkPolicy (`kubernetes/catalog/infraweaver-console/base/networkpolicy.yaml`) permits port 53 only to `kube-system`, and 443/587 to `0.0.0.0/0` minus RFC1918.

**Four consequences the design must absorb:**

1. **A conventional resolver library will not work.** Anything that opens UDP/TCP 53 to a public resolver — most Node DNS libraries when given a custom server, and every `dig` shell-out — **times out silently** from the console pod. Node's default `dns.resolveTxt()` uses the pod's `/etc/resolv.conf`, i.e. CoreDNS, which *is* reachable — but that is one cache, in-cluster, not an independent view.
2. **DNS-over-HTTPS on 443 is the only viable transport for independent verification.** Verified working.
3. **Querying the zone's authoritative nameservers directly is not currently possible from the pod** (that needs port 53 to `adam.ns.cloudflare.com`). Either the design accepts recursive-resolver-only verification, or a narrow NetworkPolicy egress rule for 53 is added. Note the circularity if only `cloudflare-dns.com` is used: it is Cloudflare's resolver validating Cloudflare-hosted zones. **Use at least two independent DoH providers** (e.g. Cloudflare and Google) and report agreement/disagreement.
4. **No SMTP-level verification is possible.** Port 25 is blocked. The addon can never confirm that an MX host answers, that STARTTLS is offered, that its certificate matches the MTA-STS policy, or that DANE would validate. Every such claim must be marked *not verified by this platform* unless a NetworkPolicy change is made — and opening egress 25 from the console is itself a decision with spam/abuse implications.

Prior sessions recorded exactly this class of bug — a console feature that looked healthy from the operator's workstation and was dead from inside the pod because of default-deny egress. **Every probe in this section was run from inside the pod for that reason.**

### 5.4 Per-record verification method

| Record | Tier A (API) | Tier B (resolution) | Tier C (behaviour) |
|---|---|---|---|
| **MX** | exact `(pref, host)` multiset matches intent; `proxied=false` | DoH `MX`; each target resolves to A/AAAA; no target is a CNAME | *Not possible from the pod* — port 25 blocked. Mark unverified. |
| **SPF** | exactly one `v=spf1` TXT at apex | DoH `TXT` apex; assert exactly one `v=spf1`; recursively expand and count lookups ≤10 and void lookups ≤2; assert `-all`/`~all`; assert `a`/`mx` are not used against a proxied apex | `rua` reports: `spf=pass` and `spf` aligned, from every authorized source |
| **DKIM** | selector record present, `p=` non-empty | DoH `TXT` at `<sel>._domainkey`; follow the CNAME if it is a CNAME; parse `v=DKIM1`, `k=`, key length | **The only real proof**: `rua` shows `dkim=pass` for the domain. DNS presence proves nothing. |
| **DMARC** | exactly one `v=DMARC1` TXT at `_dmarc`; not a CNAME | DoH `TXT _dmarc`; assert tag order (`v` first, `p` second); parse `p`, `sp`, `pct`, `adkim`, `aspf`, `rua`, `ruf`; **if `rua` is off-domain, DoH-query `<domain>._report._dmarc.<collector>` for `v=DMARC1`** | reports actually arriving; a nonzero message count |
| **MTA-STS** | `_mta-sts` TXT present with an `id` | DoH `TXT _mta-sts`; **and a real HTTPS GET of `/.well-known/mta-sts.txt` with certificate validation** (443 is open — this is fully verifiable); parse `version`/`mode`/`mx`/`max_age`; assert every live MX is covered by an `mx:` pattern; assert the served `id` intent matches the TXT | TLS-RPT reports show zero MTA-STS failures |
| **TLS-RPT** | TXT present | DoH `TXT _smtp._tls`; parse `v=TLSRPTv1` and a valid `rua` URI | reports arriving |
| **CAA** | records present | DoH `CAA` at apex; assert every CA the platform issues through is represented, including `issuewild` if wildcards are used | **a certificate renewal succeeds** — that is the only real test |
| **PTR** | n/a | `dig -x` + forward-confirm — but *outbound* only, and not the addon's to fix | provider's responsibility while a smarthost is used |
| **Autodiscover** | `proxied === false` asserted via API | DoH; assert it is not merely a wildcard match — compare against the zone's wildcard target (§3.5) | client actually autoconfigures |

### 5.5 What "proven configured" must mean in the UI

Three states, never two, and never collapsed:

- **Verified** — Tier B agrees across two independent resolvers, *and* the Tier C evidence required by the current enforcement level is present.
- **Published but unproven** — Tier A succeeded; Tier B or C has not confirmed. This is where a freshly-written record lives for up to 30 minutes, and where DKIM lives until reports arrive.
- **Unknown** — the check could not run (no reports yet; the DoH query failed; port 25 makes the check impossible). **This must never render like "fine".**

A domain is "correctly configured for mail" only when the Tier C evidence exists. Everything before that is "records written".

---

## 6. Open questions for the design phase

1. **Which mail provider backs a domain?** MX, SPF `include:`, and DKIM selectors are all provider-specific, and DKIM for hosted providers is CNAME-shaped and provider-generated. Does the addon ship a provider catalogue (Microsoft 365, Proton, Google, Hostnet, custom), and does it *fetch* DKIM values from the provider's API or require the operator to paste them?

2. **Does "add a domain to the mailing addon" default to the mail set or the never-mail set (§1.10)?** `infraweaver.net` is an empty zone. The most secure action for it is almost certainly null-MX + deny-all, not a full mail configuration. What is the default, and how is the question asked?

3. **What are the numeric gates in Phase 5?** How many messages, over how many days, from how many distinct sources, at what DKIM pass rate, before `p=quarantine` is offered? Time-based gates are a lie; volume-based gates need a number.

4. **Who collects DMARC `rua` and TLS-RPT reports?** A mailbox per domain, or one collector domain? If a collector, the `<domain>._report._dmarc.<collector>` authorization record must be published on the collector's zone for every enrolled domain (§1.4) — does the addon own that zone? And does the platform parse aggregate XML itself, or delegate to a third party (which exports every domain's mail-flow metadata to that vendor)?

5. **Where does the MTA-STS policy endpoint live, and is it proxied?** Traefik + cert-manager (platform-controlled, matches the "closed off" brief) or Cloudflare-proxied (simpler, but puts Cloudflare in the trust path for the domain's transport-security policy)? And what `max_age` ladder — start at 86400 and lengthen, or go straight to 604800?

6. **Should the addon get its own zone-scoped Cloudflare token?** (§4.1) One account-wide token is currently shared by ExternalDNS, cert-manager and the console, and the addon would be the fourth consumer and the first deliberate mail-record writer. A scoped token also gives a natural enrollment boundary.

7. **Is a NetworkPolicy egress change acceptable?** Two separate asks: (a) port 53 to the zones' authoritative nameservers, for immediate cache-free verification; (b) port 25 outbound, for SMTP-level verification of MX reachability, STARTTLS and MTA-STS certificate matching. (b) has real abuse implications. If both are refused, the addon must permanently mark those checks *unverifiable*.

8. **What is the ownership ledger, concretely?** (§3.7) Where does it live — a ConfigMap, the GitOps repo, a database? How does a reconcile distinguish "I wrote this and it drifted" from "the operator changed it deliberately"? The 2026-08-16 update-guard work used a ConfigMap for run state; is that the precedent?

9. **What happens to `infraweaver.cloud`'s existing configuration?** It has a hand-set Hostnet SPF, a `p=reject` with no reporting, no MX, and a proxied wildcard that pre-breaks MTA-STS and autodiscover. Is enrolling it a *migration* flow (distinct from onboarding a clean domain), and does the addon propose the fix or merely refuse and report?

10. **Does the addon reduce the proxied wildcard on `infraweaver.cloud`?** Explicit records for `mta-sts` and `autodiscover` beat the wildcard, but the wildcard itself remains a standing hazard for every future mail name. Removing it is a website-affecting change and outside the addon's remit — so is it a warning, a blocked-enrollment condition, or a proposed change?

11. **CAA content.** Which CAs must be listed? Cloudflare Universal SSL's CA set for this account was not readable with the current token (403). This must be established before CAA is published, or a proxied hostname's certificate renewal will fail (§3.8).

12. **DKIM TXT >255 characters via the Cloudflare API.** Does the API accept a single long `content` string and split it, or must the addon pre-split into multiple character-strings? Not verifiable read-only — no 2048-bit DKIM TXT exists in any of the seven zones today.

13. **Cloudflare Email Routing detection.** The token cannot read `/zones/{id}/email/routing` (403). Grant the scope, or accept that the addon cannot detect a zone whose MX is managed by Cloudflare Email Routing?

14. **`infraweaver.nl` also exists** in the account and was not mentioned in the brief. Is it in scope?

15. **Reconcile cadence and drift.** ExternalDNS reconciles every 2 minutes. Does the mailing addon reconcile continuously, on a schedule, or only on operator action? Continuous reconciliation of *policy* records means a hand-edit by the operator is silently reverted — which for DMARC is exactly the "control that could not work while reporting success" shape this codebase has been bitten by before.

---

## Appendix — provenance

| Claim class | How established |
|---|---|
| Zone inventory, record contents, `proxiable`/`proxied`, DNSSEC status, rate-limit headers, token scope | Cloudflare API v4 reads with the live platform token, 2026-08-16 |
| Public resolution, SOA/negative-cache TTLs, wildcard shadowing, rcode behaviour, SPF include expansion | `dig` against `1.1.1.1` and the zones' authoritative nameservers, 2026-08-16 |
| Pod egress (53/25/587/443), DoH viability | `kubectl exec` into `infraweaver-console-767bbd579d-pj57t`, 2026-08-16 |
| Credential paths, ExternalDNS policy, delete allowlist, ClusterIssuers, NetworkPolicy, `CF_ZONE_ID` resolution | Source files in `/home/runner/InfraWeaver-infra` and `/home/runner/InfraWeaver-platform`, cited inline |
| Protocol semantics (RFC 7208 SPF, 6376 DKIM, 7489 DMARC, 8461 MTA-STS, 8460 TLS-RPT, 7505 null MX, 2308 negative caching, 6186/8314 client autoconfig) | Standards knowledge, not measured here |
| **Explicitly unverified** | Cloudflare batch-DNS endpoint behaviour; >255-char TXT handling via the API; Cloudflare Universal SSL CA set for this account; Email Routing enablement state |
