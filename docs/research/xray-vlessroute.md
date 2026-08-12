# Xray facts for the forpost routing design

Research for GitHub issue #3. All claims verified against primary sources only:

- XTLS/Xray-docs-next @ `901005cf` — <https://github.com/XTLS/Xray-docs-next> (rendered at <https://xtls.github.io>; Chinese pages under `docs/config/…`, English under `docs/en/config/…`)
- XTLS/Xray-core @ `7d214f8b` — <https://github.com/XTLS/Xray-core>

## Bottom line

1. **vlessRoute auth semantics**: VLESS authentication deliberately *ignores* UUID bytes 7-8 (group 3) — the server zeroes them on both store and lookup — so any client holding a valid UUID can rewrite its own marker to `0001` and self-elevate; the only mitigation is compound routing rules that AND `vlessRoute` with `user` (client email).
2. **Compound field rules**: all fields in one routing rule are ANDed; rules are evaluated top-to-bottom, first match wins; with no match, traffic goes to the **first outbound** in the config — so the deterministic catch-all is a final rule with `"network": "tcp,udp"` (or careful outbound ordering).
3. **DNS per outbound**: a non-`+local` DNS server entry (`{"address": "192.168.30.1", "domains": ["domain:bdgn.me"], "skipFallback": true}`) emits its query as a pseudo-inbound request tagged by the DNS module's `tag`, which passes through routing and can be steered to the bastion outbound — the query does not egress directly.
4. **Chained outbounds**: VLESS+Reality as an outbound is just the normal client shape (`vless` protocol + `streamSettings.security: "reality"` with `serverName`/`fingerprint`/`password`(formerly `publicKey`)/`shortId`); no Reality-in-Reality is involved since forpost dials each upstream directly; `flow: xtls-rprx-vision` requires TCP("raw")+TLS/Reality, blocks UDP/443 unless the `-udp443` variant is used, and UDP requests are automatically wrapped in Mux/XUDP.
5. **UUID format tolerance**: xray-core's `ParseString` only checks length (32-36 chars) and hex-decodability — no RFC-4122 version/variant check — so a `0001` group-3 marker is accepted; sing-box (gofrs/uuid) likewise does no version check, and v2rayNG passes the ID string through to the bundled Xray core with no client-side validation found.
6. **Block + default**: a block is an outbound `"protocol": "blackhole"` with `"settings": {"response": {"type": "none"}}`; the recommended structure is ordered rules — privileged allow → non-privileged block for the same destinations → final `"network": "tcp,udp"` catch-all to the default outbound — so the default never depends on outbound list order.

---

## Q1. vlessRoute auth semantics — self-elevation is possible by design

**The server masks bytes 7-8 (0-indexed bytes 6-7 = UUID string group 3) out of authentication.** `ProcessUUID` zeroes both bytes, and it is applied to the configured UUID on `Add` and to the client-sent UUID on `Get`, so the lookup key never contains the route bytes:

```go
// proxy/vless/validator.go
func ProcessUUID(id [16]byte) [16]byte {
	id[6] = 0
	id[7] = 0
	return id
}
```

- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/proxy/vless/validator.go#L21-L25> (`ProcessUUID`)
- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/proxy/vless/validator.go#L35-L48> (`Add` stores `ProcessUUID(...)`)
- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/proxy/vless/validator.go#L62-L69> (`Get` looks up `ProcessUUID(id)`)

Authentication itself is a plain map lookup of the (masked) client-sent ID; a nil result rejects the request:

- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/proxy/vless/encoding/encoding.go#L94-L97> (`validator.Get(id)`; "invalid request user id" on miss)

The client-sent bytes 6-7 are then copied verbatim into the session as the routing attribute:

- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/proxy/vless/inbound/inbound.go#L538> — `inbound.VlessRoute = net.PortFromBytes(userSentID[6:8])`
- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/common/session/session.go#L50-L51> — "VlessRoute is the user-sent VLESS UUID's 7th<<8 | 8th bytes."

The official docs state this explicitly and present it as a feature ("allowing users to customize parts of the server routing … without changing any external fields"):

- <https://xtls.github.io/en/config/routing.html#ruleobject> (`vlessRoute` field; rendered from <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/en/config/routing.md#L159-L168>)

**Consequence**: any holder of a valid UUID (the other 14 bytes) can set group 3 to `0001` and match a privileged `vlessRoute` rule. There is **no server-side scoping of route values to users** in the core; the marker is not authenticated.

**Mitigation (docs/source-supported)**: make the privileged rule compound — match both `user` (the privileged clients' `email` values from the inbound `clients` list) and `vlessRoute`. `user` matches the *authenticated* account's email, which the client cannot forge. Multiple fields in one rule are ANDed (see Q2). E.g.:

```json
{
  "user": ["alice@forpost", "bob@forpost"],
  "vlessRoute": "1",
  "domain": ["domain:bdgn.me"],
  "ip": ["192.168.0.0/16"],
  "outboundTag": "bastion"
}
```

(Note: `domain` and `ip` within one rule are alternative matchers on the same target address, but both are ANDed with `user`/`vlessRoute`; see Q2 for the exact semantics and why you may want two separate rules — one `domain`-based, one `ip`-based — rather than one rule with both.)

- `user` field semantics: <https://xtls.github.io/en/config/routing.html#ruleobject> / <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/routing.md#L155-L157>

## Q2. Compound field rules — AND semantics, ordering, fallback

**AND semantics.** "当多个属性同时指定时，这些属性需要**同时**满足，才可以使当前规则生效" — when multiple attributes are specified, all must be satisfied (danger callout directly under the RuleObject schema):

- <https://xtls.github.io/config/routing.html#ruleobject> / <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/routing.md#L83-L85>

Source confirmation: a field rule builds a `ConditionChan`, and `Apply` returns false on the first failing condition (all conditions must pass):

- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/app/router/condition.go#L36-L42>

Within a single field, array items are ORed (e.g. "当某一项匹配目标 IP 时，此规则生效" — the rule takes effect when *any one item* matches):

- <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/routing.md#L102-L108> (`ip`), <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/routing.md#L155-L157> (`user`)

Caveat for the design: `domain` and `ip` in the *same* rule are both conditions on the connection's target; with `domainStrategy: "AsIs"` (default) a domain-targeted connection has no IP, so a rule containing both `domain` and `ip` will not match domain requests unless the domain gets resolved (see Q3/`domainStrategy`). The safer pattern is two rules: one `{user, vlessRoute, domain: ["domain:bdgn.me"]}` and one `{user, vlessRoute, ip: ["192.168.0.0/16"]}` (and matching block rules for everyone else).

**Ordering and fallback.** Rules are evaluated top-to-bottom and the first matching rule wins; with no match, traffic goes to the **first outbound** in the config:

> 对于每一个连接，路由将根据这些规则从上到下依次进行判断，当遇到第一个生效规则时，即将这个连接转发至它所指定的 `outboundTag` 或 `balancerTag`。
> 当没有匹配到任何规则时，流量默认由第一个 outbound 发出。

- <https://xtls.github.io/config/routing.html#routingobject> / <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/routing.md#L43-L46>

Source: the dispatcher falls back to `GetDefaultHandler()`, and the outbound manager's `defaultHandler` is the first handler added (i.e. the first outbound in the config):

- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/app/dispatcher/default.go#L478>
- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/app/proxyman/outbound/outbound.go#L82-L91> and <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/app/proxyman/outbound/outbound.go#L109-L110> ("if `m.defaultHandler == nil` { set }" on add)

**Catch-all pattern.** The docs themselves recommend a terminal rule with `"network": "tcp,udp"` as catch-all, "放在所有路由规则的最末尾用于指定没有任何其他规则时使用的默认出站（否则核心默认走第一个出站）":

- <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/routing.md#L137>

`vlessRoute` itself is parsed as a `PortList` (same syntax as `port`: `"53,443,1000-2000"`, big-endian uint16 of the two bytes, so marker `0001` → `1`) and matched with `v.port.Contains(ctx.GetVlessRoute())`:

- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/infra/conf/router.go#L144> and <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/infra/conf/router.go#L241-L242>
- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/app/router/condition.go#L134-L135>
- Encoding to decimal: <https://xtls.github.io/en/config/routing.html#ruleobject> ("0001→1, 000e→14, 38b2→14514")

## Q3. DNS per outbound — resolving bdgn.me at 192.168.30.1 through the bastion

**Mechanism.** The built-in DNS module supports per-server `domains` scoping; matching servers are tried first (list 1), others are fallback (list 2, skipped with `disableFallbackIfMatch`/`skipFallback`):

- <https://xtls.github.io/config/dns.html#dns-object> ("DNS 处理流程") / <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/dns.md#L34-L47>
- DnsServerObject fields (`domains`, `skipFallback`, `expectedIPs`, `queryStrategy`, `tag`): <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/dns.md#L258-L290>

**Crucially, a non-local DNS server's query goes through the routing system**, so it can be steered into the bastion outbound instead of egressing directly:

> 非 local 默认将视为一个从 tag 为 dns.tag 的入站进来的请求，将经过正常的核心处理流程，可能会被路由模块分配去本地 freedom 或者其他远端出站

- <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/dns.md#L296-L303> (tip "关于 local 模式和 DNS 服务器本身的域名", under DnsServerObject `address`)
- "DNS 服务器默认进入路由系统进行匹配" (TIP 1): <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/dns.md#L18>
- Only `+local` variants (`tcp+local://`, `https+local://`, `quic+local://`) bypass routing via a direct freedom dial; plain `"192.168.30.1"` (UDP) or `"tcp://192.168.30.1"` (DoT-plain TCP) follow routing: <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/dns.md#L122-L138>

The DNS module's global `tag` lets routing match its queries with `inboundTag` ("由内置 DNS 发出的查询流量，除 localhost、fakedns、TCPL、DOHL 和 DOQL 模式外，都可以用此标识在路由使用 inboundTag 进行匹配"):

- <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/dns.md#L252-L254>

So the forpost config sketch is:

```json
"dns": {
  "servers": [
    { "address": "192.168.30.1", "domains": ["domain:bdgn.me"], "skipFallback": true },
    "localhost"
  ],
  "tag": "dns-internal"
}
```

plus a routing rule sending `{ "inboundTag": ["dns-internal"], "ip": ["192.168.30.1/32"] }` (or just the destination-IP rule `192.168.0.0/16`) to the bastion outbound. Since 192.168.30.1 is an IP literal there is no resolution loop. The docs also note DNS-originated queries automatically skip `IPIfNonMatch`/`IPOnDemand` re-resolution precisely to avoid loops:

- <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/dns.md#L299-L303> (same tip: "DNS 模块非 local 模式发出的 DNS 请求将会自动在路由模块中跳过 IPIfNonMatch 和 IPOnDemand 的解析过程")

**When this DNS path is exercised at all.** The built-in DNS is used for routing decisions only when `routing.domainStrategy` is `IPIfNonMatch` or `IPOnDemand`; with the default `AsIs` the domain is matched as a string and never resolved by forpost:

- <https://xtls.github.io/config/routing.html#routingobject> (`domainStrategy`) / <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/routing.md#L22-L36>

Note the docs' nuance: "无论解析与否，路由系统不会影响真正目标地址，请求的目标仍然是原始目标" — routing-triggered resolution does not rewrite the dial target. In the forpost design the bastion outbound receives the domain `bdgn.me` as-is inside VLESS and the *bastion* resolves it; forpost's own DNS only matters if an `ip`-condition rule (e.g. `192.168.0.0/16`) must match domain-named requests, i.e. `domainStrategy: "IPIfNonMatch"`.

**Sniffing interaction.** With inbound `sniffing.enabled` + `destOverride: ["http","tls"]`, sniffed domains replace the target for routing; adding `"routeOnly": true` keeps the original dial target and uses the sniffed domain only for routing. With `routeOnly` + `AsIs` you get domain and IP分流 with zero local DNS ("全程无 DNS 解析"), and if resolution *does* happen the router sees the resolved IP, not the original ("路由系统只能看到由域名解析出的 IP 而无法看见原始目标 IP"):

- <https://xtls.github.io/config/inbound.html#sniffingobject> / <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/inbound.md#L146-L153> and <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/routing.md#L28-L36>

`expectedIPs`/`unexpectedIPs` on the DNS server can additionally validate that answers for bdgn.me really are inside `192.168.0.0/16`:

- <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/dns.md> (DnsServerObject `expectedIPs`)

## Q4. Chained outbounds — VLESS+Reality as a client

Config shape (current flat form; the legacy `vnext` form is still accepted and internally converted — exactly one vnext with one user):

- <https://xtls.github.io/config/outbounds/vless.html> / <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/outbounds/vless.md#L11-L37>
- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/infra/conf/vless.go#L239-L280>

```json
{
  "protocol": "vless",
  "tag": "bastion",
  "settings": {
    "address": "bastion.example.com",
    "port": 443,
    "id": "xxxxxxxx-xxxx-0001-xxxx-xxxxxxxxxxxx",
    "encryption": "none",
    "flow": "xtls-rprx-vision"
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "serverName": "www.example.com",
      "fingerprint": "chrome",
      "password": "<upstream server public key>",
      "shortId": "0123456789abcdef"
    }
  }
}
```

Client-side Reality fields are `serverName`, `fingerprint`, `password` (formerly `publicKey` — "旧称 publicKey, 为防止误解更名"), `shortId`, `spiderX`:

- <https://xtls.github.io/config/transports/reality.html> / <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/transports/reality.md#L55-L60> and <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/transports/reality.md#L197-L199>

Gotchas relevant to forpost:

- **`encryption` must be set explicitly** ("不能留空，禁用需显式设置为 `"none"`"): <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/outbounds/vless.md#L63-L67>
- **`flow: xtls-rprx-vision` requires TCP("raw")+TLS or Reality** ("XTLS 仅在以下搭配下可用: TCP+TLS/REALITY …"): <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/outbounds/vless.md#L85-L101>. Vision **blocks UDP/443** outbound unless the `xtls-rprx-vision-udp443` variant is used: same doc, and source <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/proxy/vless/outbound/outbound.go#L259-L262>.
- **UDP over a vision outbound is auto-wrapped in Mux (XUDP)**: when the request is UDP and flow is XRV, the client converts the command to Mux (`v1.mux.cool:666`), so UDP DNS to 192.168.30.1 still works through the bastion: <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/proxy/vless/outbound/outbound.go#L315-L319>. (If you want to avoid that layer, use `"tcp://192.168.30.1"` in the DNS server entry — plain DNS over TCP also follows routing: Q3 sources.)
- **Mux is client-side only; the server adapts automatically** ("Mux 只需要在客户端启用，服务器端自动适配"), so no upstream config change is needed if forpost enables `mux` on its outbounds — but Mux "是为了减少 TCP 的握手延迟而设计，而非提高连接的吞吐量" and often hurts bulk transfers: <https://xtls.github.io/config/outbound.html#muxobject> / <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/outbound.md#L112-L136>.
- **Reality-through-Reality is not involved**: forpost terminates the client Reality and originates a fresh Reality handshake to each upstream; each hop is an independent VLESS+Reality session. Nothing in the docs or source couples the two layers. (Splice note: kernel splice for vision requires the inbound to be a "pure" TCP proxy or XTLS inbound — with nginx in front, check whether the nginx→xray hop preserves that; docs list the splice conditions: <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/outbounds/vless.md> tip "关于 Splice".)
- The outbound's `id` group-3 bytes are masked by the *upstream* the same way (Q1) — i.e. forpost controls its own vlessRoute toward the bastion/alwyzon if those servers route on it.

## Q5. UUID format tolerance — group-3 markers are accepted

**xray-core parser** (`common/uuid/uuid.go ParseString`): accepts 32-36 chars, skips `-` at group boundaries, hex-decodes each group. There is **no version or variant validation** anywhere in the parse path — arbitrary hex in group 3 (e.g. `0001`) parses fine. Strings shorter than 32 chars are instead mapped deterministically to a UUID via SHA-1 (the VLESS UUID mapping standard, XTLS/Xray-core#158):

- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/common/uuid/uuid.go#L67-L112>
- Mapping standard referenced by the docs ("VLESS UUID 映射标准：将自定义字符串映射为一个 UUIDv5", id "可以是任意小于 30 字节的字符串, 也可以是一个合法的 UUID"): <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/outbounds/vless.md#L47-L57>

Only `uuid.New()` (random generation) sets v4 version/variant bits — irrelevant for parsing:

- <https://github.com/XTLS/Xray-core/blob/7d214f8b094f75322fa3990f8aadad1c912f24f5/common/uuid/uuid.go#L48-L55>

**Client interop (source-level):**

- **sing-box**: parses the VLESS UUID with `github.com/gofrs/uuid` `FromString`, falling back to a v5 mapping on error: <https://github.com/SagerNet/sing-vmess/blob/main/vless/client.go#L27-L37>. gofrs' parse path (`fromHexChar`/`parseBytes`, called by `FromString`) does pure hex decoding with no version/variant check: <https://github.com/gofrs/uuid/blob/master/codec.go>.
- **v2rayNG**: I found **no client-side UUID validation** in its config-building layer (`fmt/FmtBase.kt`, `fmt/VlessFmt.kt`, `util/Utils.kt` contain no UUID parse/validate of the server id); the id string is passed through into the generated config consumed by the bundled core. Repo: <https://github.com/2dust/v2rayNG> (`V2rayNG/app/src/main/java/com/v2ray/ang/fmt/`). I did not verify which core version a given v2rayNG release bundles — treat the "no validation" finding as applying to the share/config layer, with final parsing done by the core's tolerant `ParseString` above.
- **Streisand (iOS)**: NOT verified from primary sources — I did not locate its UUID validation path; treat as unknown. Given its sing-box lineage this is expected to be tolerant, but that is inference, not evidence.

Also note the direction of strictness: even a *hypothetical* strict RFC-4122 validator would reject `…-0001-…` for the wrong *version nibble*, not for the marker per se. Since auth masks group 3 entirely (Q1), an operational fallback is to keep marker `0000` in stored/provisioned UUIDs and let privileged clients set `0001` only in their local config — but that does nothing to prevent self-elevation; the `user`+`vlessRoute` compound rule (Q1) is the actual control.

## Q6. Block + default — blackhole and catch-all structure

**Block outbound** — `blackhole` protocol; with `"response": {"type": "none"}` (the default) it just closes the connection; `"http"` sends a 403 first. Combined with routing "可以达到禁止访问某些网站的效果":

- <https://xtls.github.io/config/outbounds/blackhole.html> / <https://github.com/XTLS/Xray-docs-next/blob/901005cfbb887f20b60db4d59b5bce466206f5f3/docs/config/outbounds/blackhole.md>

```json
{ "protocol": "blackhole", "tag": "block", "settings": { "response": { "type": "none" } } }
```

**Recommended rule structure** for the forpost design (order matters — first match wins, Q2):

```json
"routing": {
  "domainStrategy": "IPIfNonMatch",
  "rules": [
    { "user": ["alice@forpost"], "vlessRoute": "1", "domain": ["domain:bdgn.me"], "outboundTag": "bastion" },
    { "user": ["alice@forpost"], "vlessRoute": "1", "ip": ["192.168.0.0/16"], "outboundTag": "bastion" },
    { "domain": ["domain:bdgn.me"], "outboundTag": "block" },
    { "ip": ["192.168.0.0/16"], "outboundTag": "block" },
    { "inboundTag": ["dns-internal"], "outboundTag": "bastion" },
    { "network": "tcp,udp", "outboundTag": "alwyzon" }
  ]
}
```

The final `"network": "tcp,udp"` rule is the docs-blessed catch-all, making the default deterministic regardless of outbound list order; without it, unmatched traffic silently uses the *first* outbound (Q2 sources: docs routing.md L43-46 + L137; source dispatcher/default.go L478 + proxyman/outbound/outbound.go L109-110). Outbound order still matters as defense-in-depth: put `alwyzon` (or a dedicated default) first, never `bastion`.

Note the block rules intentionally have **no** `user`/`vlessRoute` condition so they catch non-privileged users *and* any privileged-marker self-elevation attempt that fails the compound `user` check — the compound privileged rules being first is what carves out the exception.

## Not verifiable from primary sources

- Streisand's UUID validation behavior (Q5) — not checked at source level.
- Which exact core version v2rayNG bundles per release (Q5).
- No docs statement found that explicitly says "vlessRoute can be abused for privilege escalation; combine with `user`" — the masking behavior is documented and confirmed in source, and the `user`+AND semantics are documented; the composition of the two as a mitigation is our inference from those primary facts.
