# Xray facts for forpost multi-domain Reality (two SNIs on one node)

Question: can xray accept VLESS+Reality client connections on two public domains
(`loft.bdgn.me` AND `htz.bdgn.me`) on the same node, with identical users/fallbacks/routing,
and what must change in each layer of the forpost setup (SPEC §6-§8)?

All claims verified against primary sources only:

- XTLS/Xray-docs-next @ `901005cf` — <https://github.com/XTLS/Xray-docs-next> (local clone at
  `/Users/ruabdid/projects/homelab/Xray-docs-next`; rendered at <https://xtls.github.io>)
- XTLS/Xray-core @ `v26.3.27` — <https://github.com/XTLS/Xray-core> (the version pinned in
  `forpost/units/40-xray.sh:26`, `xray_version="v26.3.27"`)
- xtls/reality @ `9234c772ba8f` — <https://github.com/xtls/reality>, the REALITY implementation
  vendored by Xray-core v26.3.27 per its go.mod
  (<https://github.com/XTLS/Xray-core/blob/v26.3.27/go.mod>, `github.com/xtls/reality v0.0.0-20260322125925-9234c772ba8f`)
- nginx docs — <https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html>,
  <https://nginx.org/en/docs/stream/ngx_stream_map_module.html>,
  <https://nginx.org/en/docs/http/configuring_https_servers.html>

## Bottom line

**Yes — one xray inbound serves both domains.** The total diff is:

1. **xray** (`templates/xray-config.json.j2`): `serverNames: [loft.bdgn.me, htz.bdgn.me]` — the field is a
   list by design, matched as a set against the client SNI; one `privateKey`, one `shortIds` list, one
   `clients` list serve both. No other xray change: auth, routing, stats are SNI-independent.
2. **nginx stream** (`templates/nginx.conf.j2`): add `htz.bdgn.me → vless-reality` to the
   `$ssl_preread_server_name` map. That is the whole change at that layer; the `default → 418` route
   is untouched.
3. **nginx fallback** (`templates/fallback.conf.j2`): the cert at `/usr/ssl/fullchain.crt` must cover
   **both** names (one SAN cert is enough). The vhost needs no second server block — with a single
   block on `127.0.0.1:8443` it is the default server and nginx ignores the `server_name` for
   selection — but listing both names is good hygiene. xray passes the client's original SNI through
   to dest verbatim, so nginx SNI-based vhost/cert selection "just works" if you ever split blocks.
4. **Cert issuance** (`ansible/add-ssl-certificate.yaml` via `create-forpost.yaml:124`): extend
   `sites` to `-d {{ forpost.domain }} -d htz.bdgn.me`; the play's SAN-coverage idempotency check
   already loops over every `-d` name, so the re-issue triggers correctly. Both names are in the
   `bdgn.me` zone, so the existing `cf_token`/`cf_zone_id` suffice.
5. **Clients**: per-domain share links differ only in the host and `sni=` parameter; the same UUID,
   `pbk`, `sid`, and `fp=chrome` work on both domains. Issue two links per user (or let clients
   switch one field).
6. **DNS**: a public A record for `htz.bdgn.me` → node IP (manual, per SPEC §10).

---

## Q1. Reality `serverNames` — a list by design, one keypair serves all entries

**Docs.** The server-side field is `serverNames: [string]`, shown in the docs' own example with two
names (`["example.com", "www.example.com"]`) next to a single `privateKey`:

- <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/transports/reality.md#L35> (example) and `.../reality.md#L96-L100` (field doc: "客户端可用的 `serverName` 列表，不支持 \* 通配符" — list of usable client serverNames, no wildcards)

**Config plumbing (v26.3.27).** The JSON array is converted to a membership set
(`map[string]bool`), one entry per name — no per-name keying anywhere:

- <https://github.com/XTLS/Xray-core/blob/v26.3.27/transport/internet/reality/config.go#L50-L53> —
  `config.ServerNames = make(map[string]bool); for _, serverName := range c.ServerNames { config.ServerNames[serverName] = true }`
- Empty list is rejected at config build: <https://github.com/XTLS/Xray-core/blob/v26.3.27/infra/conf/transport_internet.go#L847-L849>

**Handshake behavior (xtls/reality @ 9234c772).** For every connection the server reads the
ClientHello and gates the *authentication attempt* on set membership:

- <https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L211> —
  `if copying || err != nil || hs.c.vers != VersionTLS13 || !config.ServerNames[hs.clientHello.serverName] { break }`

If the SNI is in the set, the server derives the auth key from the *same* `privateKey` regardless of
which name was presented (X25519(privateKey, client ephemeral) → HKDF; then AEAD-open of the session
id with the raw ClientHello as associated data), checks `shortIds` membership, and accepts:

- <https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L230> (X25519 with the single `config.PrivateKey`)
- <https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L245> (`aead.Open(..., hs.clientHello.original)`)
- <https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L259-L261> (shortId check → `hs.c.conn = conn`, i.e. authenticated)

So a client presenting SNI=B with `serverNames=[A,B]` gets a **fully normal authenticated session**,
byte-identical in handling to SNI=A. (Verified in source; the per-name code path is a map lookup only.)

**SNI not in the list → pure dest mirroring.** The connection falls out of the auth loop and becomes
transparent bidirectional forwarding between client and `dest` — the prober completes a real TLS
handshake with dest and sees dest's genuine certificate:

- fallback forwarding: <https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L271-L283>
  and <https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L441-L442>
- failure reason logged as `server name mismatch: <sni>`: <https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L466-L467>
- docs confirm the design: "Xray 对于鉴权失败（非合法 REALITY 请求）的流量，会**直接转发**至 target" — <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/transports/reality.md#L85>

**Constraints per serverName:**

- TLS 1.3 is mandatory for the auth path (`hs.c.vers != VersionTLS13` → fallback, tls.go L211 above);
  dest must also answer TLS 1.3 with an X25519 (or X25519MLKEM768) key share because the server
  mirrors dest's handshake messages: <https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L356-L359>
- No wildcard support (docs, reality.md L96-L100 above).
- Docs guidance: serverNames should "一般与 target 保持一致" (generally stay consistent with target) and
  the practical set is "any SNI the server accepts … reference the returned certificate's SAN" —
  <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/transports/reality.md#L100>.
  For forpost, dest is our own nginx vhost, so this guidance reduces to: the fallback cert's SAN list
  should cover both names (see Q2).
- An empty-string entry `""` accepts no-SNI connections (reality.md L102) — not needed here.

**Keypair sharing.** Nothing in the docs or source couples the x25519 keypair to a domain: the key is
per-inbound, `serverNames` is per-inbound, and the docs' two-name example uses one `privateKey`.
Sharing one keypair across both domains is the designed configuration. (Inference, not a documented
statement: the only downside of sharing is that you cannot rotate/revoke per domain — a key change
invalidates both domains' links at once.)

## Q2. The dest/fallback side — SNI is passed through verbatim; cert must cover both names

**Mechanism (verified in source).** xray dials `dest` with a raw TCP connection (`config.Type` is
`"tcp"`; no TLS is initiated by xray — <https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L168>),
writes the PROXY v1 header immediately when `xver: 1`
(<https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L174-L179>),
and then **mirrors every byte the client sends — including the original ClientHello with its
original SNI — to dest** via `MirrorConn.Read`:

- <https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L70-L84> —
  `n, err := c.Conn.Read(b); ... if n != 0 { c.Target.Write(b[:n]) }`

Therefore nginx on `127.0.0.1:8443` sees the prober's (or client's) true SNI in the TLS ClientHello,
and nginx's normal SNI-based certificate/vhost selection applies. Per nginx docs, SNI "allows a
browser to pass a requested server name during the SSL handshake and, therefore, the server will
know which certificate it should use"; without a matching `server_name` the **default server's**
certificate is served regardless of the requested name:

- <https://nginx.org/en/docs/http/configuring_https_servers.html> ("Name-based HTTPS servers",
  "A single certificate for several server names" sections)

**Consequence for forpost.** `fallback.conf.j2` has the *only* server block on `127.0.0.1:8443`, so
it is the default server and always answers — but with its single configured certificate. Today that
cert covers only `{{ forpost.domain }}` (issued with `sites: "-d {{ forpost.domain }}"`,
`create-forpost.yaml:124`). A prober connecting with SNI=`htz.bdgn.me` would receive a certificate
whose SANs say `loft.bdgn.me` — an SNI/cert mismatch that breaks the camouflage story for the second
domain (the whole point of pointing dest at a real-serving vhost is that a probe of
`https://htz.bdgn.me/` is indistinguishable from a real server for that name). Two fixes, both valid:

- **(a) one SAN cert covering both names** (recommended; matches the existing issuance play — Q5).
  Keep the single vhost; optionally extend `server_name` to both names for documentation. nginx
  serves the same cert for both SNIs; both SANs match.
- **(b) two server blocks on `127.0.0.1:8443`**, each with `listen ... ssl proxy_protocol;`, its own
  `server_name` and cert. SNI-based selection then picks per-domain certs. More moving parts; no
  functional advantage here since both blocks would proxy the same upstream.

Note the `proxy_protocol` listen flag and the `set_real_ip_from 127.0.0.1` / `real_ip_header
proxy_protocol` pair are per-listen-socket and unchanged — xray sends PROXY v1 on *every* dest dial
(tls.go L174-L179 above, before the ClientHello is even read), including fallback connections, so
both domains inherit the real-client-IP behavior with no change.

**Authenticated clients do not need the dest cert to match.** The certificate an authenticated
Reality client sees is xray's ephemeral per-session ed25519 certificate (validated via HMAC of the
auth key), not dest's certificate — dest's handshake is only *mirrored structurally* (record types
and lengths). So even with option (a) not yet applied, client connections on `htz.bdgn.me` would
work; only the probe-visible camouflage would be wrong. (Verified: the dest dial is raw TCP with no
cert validation by xray, tls.go L168; ephemeral-cert validation is client-side against the auth key,
<https://github.com/XTLS/Xray-core/blob/v26.3.27/transport/internet/reality/reality.go#L85-L110>.)

## Q3. nginx stream SNI map — one map line is the whole change

`ssl_preread on` only *extracts* the SNI from the ClientHello "without terminating SSL/TLS"
(<https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html>); the stream `map` matches
`$ssl_preread_server_name` as a plain string (exact, case-insensitive) with `default` as the
no-match value (<https://nginx.org/en/docs/stream/ngx_stream_map_module.html>). So in
`templates/nginx.conf.j2`:

```
map $ssl_preread_server_name $upstream_map {
        default               main;
        loft.bdgn.me          vless-reality;
        htz.bdgn.me           vless-reality;   # ← the entire stream-layer change
}
```

No subtlety with the `default` route: it still catches every other SNI (and empty SNI) → 418 site.
`proxy_protocol on` on the stream server applies per-upstream-server-block, so xray receives the
PROXY header for both domains exactly as today; `sockopt.acceptProxyProtocol` on the inbound needs
no change. One caution (inference from the map semantics): the map keys are exact strings, so the
apex `bdgn.me` or `www.*` names still fall to the 418 default — add explicit keys if ever wanted.

## Q4. Client contract — only host + `sni=` differ

The share-link format (SPEC §8) gains a second variant per user:

```
vless://<uuid>@loft.bdgn.me:443?security=reality&sni=loft.bdgn.me&fp=chrome&pbk=<pub>&sid=01&flow=xtls-rprx-vision&type=tcp#<name>@loft
vless://<uuid>@htz.bdgn.me:443?security=reality&sni=htz.bdgn.me&fp=chrome&pbk=<pub>&sid=01&flow=xtls-rprx-vision&type=tcp#<name>@htz
```

- **Same UUID on both**: VLESS UUID authentication happens *inside* the established Reality session
  and is SNI-independent (the `clients` list is per-inbound; nothing in the VLESS auth path reads
  the TLS SNI — cf. the validator lookup in xray-vlessroute.md Q1).
- **Same `pbk`/`sid`/`fp`**: there is one `privateKey` (→ one `pbk`) and one `shortIds` list for the
  inbound; docs define the client `serverName` as simply "服务端 `serverNames` 之一" (one of the
  server's serverNames) — <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/transports/reality.md#L179>.
- The Reality auth *is* cryptographically bound to the exact ClientHello bytes (the AEAD associated
  data is the raw ClientHello, which includes the SNI — client side:
  <https://github.com/XTLS/Xray-core/blob/v26.3.27/transport/internet/reality/reality.go#L174>,
  server side: tls.go L245 in Q1). This does not create per-domain state: the client builds its
  hello from its own configured `sni`, and the server accepts any SNI in the set. It only means a
  client cannot replay another client's hello bytes with a different SNI.
- Routing, privilege split, DNS hijack, and stats are all keyed on the authenticated `email`, so
  per-user behavior is identical whichever domain the client connects to.

## Q5. Cert issuance — extend the `sites` list

`create-forpost.yaml` line 124 currently passes `sites: "-d {{ forpost.domain }}"` to
`ansible/add-ssl-certificate.yaml`, which runs `acme.sh --issue {{ sites }} --dns dns_cf` (one
`-d` per name → one certificate with both names in the SAN list). Change to:

```yaml
sites: "-d {{ forpost.domain }} -d {{ forpost.server_name_alt }}"   # or a second literal -d htz.bdgn.me
```

The play's idempotency guard already iterates over every non-`-d` token in `sites` and greps the
deployed cert's `subjectAltName`, re-issuing if any requested name is missing — so adding the second
name triggers exactly one re-issue on the next apply (this guard was written for precisely this
rename/extend case; see the comment block in `ansible/add-ssl-certificate.yaml`). Both names are in
the `bdgn.me` Cloudflare zone, so the existing `cf_token` / `cf_zone_id` cover the DNS-01 challenge
for both; no token or zone changes. The fallback, default, and xform vhosts all read the same
`/usr/ssl/fullchain.crt` + `certificate.key`, so no template path changes; the xform vhost's
`server_name {{ forpost.domain }}` keeps working because the cert's SAN list still contains it.

## Q6. Gotchas and version notes (pinned xray v26.3.27)

- **`minClientVer` docs/code discrepancy.** The docs claim the default is `26.3.27` ("默认值为
  `26.3.27`" — <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/transports/reality.md#L114>),
  but in Xray-core v26.3.27 the field defaults to nil and the version check is skipped
  (`config.MinClientVer == nil ||` — <https://github.com/xtls/reality/blob/9234c772ba8f181f31c3e81dc2b4177322e5a9a9/tls.go#L257>;
  nil default: <https://github.com/XTLS/Xray-core/blob/v26.3.27/infra/conf/transport_internet.go#L856-L868>
  only parses when set). Treat the docs as describing a later default; re-check at every xray
  upgrade, because a real `26.3.27` floor would silently reject older client cores.
- **`dest` → `target` rename** in v26.3.27: the two are aliases
  (<https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/transports/reality.md#L78>;
  code: <https://github.com/XTLS/Xray-core/blob/v26.3.27/infra/conf/transport_internet.go#L812-L814>).
  The existing `dest` keeps working; multi-domain changes neither field.
- **Bundled reality lib version**: v26.3.27 pulls xtls/reality @ 9234c772, which includes
  `maxUselessRecords` (ChangeCipherSpec etc.) detection — unrelated to multi-domain, noted for
  completeness.
- **Certificate Transparency linkage (factual)**: one SAN cert for both names publishes the
  `loft`+`htz` pairing in public CT logs — "Let's Encrypt submits all certificates we issue to CT
  logs" (<https://letsencrypt.org/docs/ct-logs/>); CT logs store the full certificate, so its SAN
  list is public (the SAN-visibility step is inference from what a cert contains, not a quote).
  If that linkage matters, use option (b) in Q2 with two separately-issued certs. Note the A records
  already link both names to the same IP publicly, so CT adds little — but it is the delta.
- **Two domains on one IP**: nothing in the xray/REALITY primary sources warns against multiple
  SNIs per inbound; the docs' own example is two names. Any "active-probing correlation" risk of
  serving two domains from one IP is **not documented in primary sources** — speculation only. The
  one documented warning relevant here is the opposite mistake: pointing `dest` at a third-party CDN
  turns your server into an open relay
  (<https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/transports/reality.md#L85-L91>);
  forpost's dest is the local nginx vhost, so it is unaffected, and stays unaffected with two names.
- **PROXY protocol lockstep** (`tests/proxy-protocol.sh`) is unaffected: both PROXY hops are
  per-socket, not per-SNI. Keep the test green after the change.

## Not verifiable from primary sources

- Any client-GUI quirks when two share links share one UUID (per-app behavior; not checked).
- Quantitative active-probing correlation risk of two SNIs on one IP (Q6) — no primary source found.
- The exact future xray release in which the documented `minClientVer` default takes effect (Q6).
