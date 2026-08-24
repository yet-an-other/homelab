# forpost — cloud VPN entry node

Status: **created**. 
([issue #2](https://github.com/yet-an-other/homelab/issues/2)) and its resolved tickets
([#3](https://github.com/yet-an-other/homelab/issues/3),
[#5](https://github.com/yet-an-other/homelab/issues/5),
[#6](https://github.com/yet-an-other/homelab/issues/6),
[#7](https://github.com/yet-an-other/homelab/issues/7)), plus the xform deployment
([#14](https://github.com/yet-an-other/homelab/issues/14)).
Domain vocabulary: `CONTEXT.md`. xray facts: `docs/research/xray-vlessroute.md`.

## 1. Purpose and topology

**forpost** is a VPN entry node on a cloud Ubuntu VM (AWS/Azure/anything with SSH). It accepts
VLESS+Reality client connections and routes, entirely inside xray (no WireGuard):

- **default** traffic → **alwyzon** (external exit VM, not managed in this repo) via a VLESS+Reality outbound
- **internal** destinations (`domain:bdgn.me`, `192.168.0.0/16`) for **privileged users** → **bastion**
  (existing internal VM) via a VLESS+Reality outbound
- `192.168.0.0/16` for non-privileged users → **blocked**
- non-privileged `bdgn.me` → default route (the domain has public records)

```
client ──VLESS+Reality──> forpost ──VLESS+Reality──> alwyzon ──> internet
                             │
                             └──VLESS+Reality──> bastion ──> internal VMs
                             (privileged users, internal destinations only)

operator ──HTTPS :9443──> nginx ──HTTP loopback──> xform
                                           │
                                           └──gRPC loopback──> xray StatsService + HandlerService
```

Privilege is enforced by the **authenticated email tag** in xray (`user` field in routing rules).
vlessRoute was evaluated and rejected for forpost's privilege model: markers are unauthenticated and add a
per-connection toggle nobody needs (#3, #7). UUIDs are plain v4 — no marker semantics on forpost's own
inbound/links. One deliberate exception: the outbound **dial** to bastion carries the group-3 `0001`
marker (derived in §6) — that is path selection on the bastion leg (bastion's own `vlessRoute` rule),
not privilege enforcement; forpost is the sole holder of that UUID, so the marker adds no exposure.

## 2. Repo layout (#5, #6)

```
forpost/
├── SPEC.md                  # this file
├── create-forpost.yaml      # the play: thin orchestration (render + transport + invoke)
├── bootstrap.sh             # entrypoint: runs units in lexical order
├── units/                   # idempotent, numbered; the source of truth for node state
│   ├── lib/
│   │   ├── install-xray.sh  # vendored copy of frontgate/install-xray.sh
│   │   └── zmx-select.sh    # vendored copy of cloud-init/zmx-select.sh
│   ├── 00-packages.sh
│   ├── 01-unattended-upgrades.sh
│   ├── 10-user-sshd.sh
│   ├── 20-shell.sh
│   ├── 21-fonts.sh
│   ├── 30-editor.sh
│   ├── 31-tools.sh
│   ├── 40-xray.sh
│   ├── 41-nginx.sh
│   ├── 42-ufw.sh
│   └── 43-xform.sh
├── templates/
│   ├── xray-config.json.j2
│   ├── nginx.conf.j2
│   ├── default.conf.j2
│   ├── fallback.conf.j2
│   ├── xform.conf.j2
│   └── xform.service.j2
├── tests/
│   ├── proxy-protocol.sh    # PROXY protocol pair lockstep (run by the play after render)
│   └── xform-updater.sh     # isolated release/update lifecycle seam
└── user-data.yaml           # slim reachability-only cloud-init, pasted at VM creation
```

Principles: bash units do the work; Ansible renders secrets into templates and transports; every unit
is idempotent and individually re-runnable; plays never generate key material; download units are
arch-aware via `dpkg --print-architecture` (x86_64 primary, arm64 supported).

`bootstrap.sh`: `set -euo pipefail`; runs `units/[0-9][0-9]-*.sh` in order; supports
`--only <NN|name>` and `--from <NN>` for iteration; logs per-unit to `/var/log/forpost/`.

Staging path on the node: `/usr/local/sbin/forpost/` (bootstrap + units). Templates are rendered by the
play before the corresponding unit runs: the xray config directly to its final destination
(`/usr/local/etc/xray/config.json`); the nginx confs into staging under `/usr/local/sbin/forpost/nginx/` —
`41-nginx.sh` places them (units place, verify, restart, §5). The xform systemd unit is staged under
`/usr/local/sbin/forpost/xform/` and placed by `43-xform.sh`.

## 3. Secrets (#6)

Two additions to `ansible/inventory.secret.yaml`, documented in `ansible/template-proxmox-inventory.yaml`:

**Host entry** (under the inventory's hosts, alongside the Proxmox nodes):

```yaml
forpost:
  ansible_host: <vm-public-ip>
  ansible_user: ib
  ansible_ssh_private_key_file: <path>   # same key the repo already uses
```

**Vars section** (following the existing `bastion:` pattern):

```yaml
forpost:
  domain: fp1.bdgn.me              # node public name; manual A record → ansible_host
  server_name: fp1.bdgn.me         # Reality SNI; normally == domain
  backup_domain: htz.bdgn.me       # OPTIONAL: second client-facing name — same inbound,
                                   # users, fallbacks; own manual A record required (§10)
  private_key: <x25519-private>    # xray x25519
  short_ids: ["01", "02"]
  users:
    - { name: admin, uuid: <uuid-v4>, privileged: true }
    - { name: mom,   uuid: <uuid-v4>, privileged: false }
  alwyzon:                         # forpost's CLIENT credentials on alwyzon's xray
    address: <alwyzon-host>
    port: 443
    uuid: <uuid>
    server_name: <alwyzon-reality-sni>
    public_key: <alwyzon-x25519-pub>
    short_id: "01"
  bastion:                         # forpost's CLIENT credentials on bastion's xray
    address: <externally-reachable bastion xray endpoint>
    port: 443
    uuid: <uuid>
    server_name: <bastion-reality-sni>
    public_key: <bastion-x25519-pub>
    short_id: "01"
```

Key material is human-generated once and pasted in. Helper commands (documented in the playbook
header comments; optional `genkeys.sh` may print a ready-to-paste block):

```bash
xray x25519                 # → private_key; public key is derived for client links
xray x25519 -i <private>    # derive public key for the client contract (§8)
uuidgen                     # per user
```

Multi-node later = more host entries + suffixed vars sections (`forpost_fra: …`); out of scope now.

## 4. Baseline units (#5)

Full replica of `cloud-init/cloud-init-ubuntu.yaml`; nothing trimmed. The cloud-init file remains
the reference; the units are the executable source of truth.

| Unit | Does | Idempotency guard |
|---|---|---|
| `00-packages.sh` | `apt-get update/upgrade`; install `sudo zsh btop curl openssl git gcc unzip zip jq fontconfig ca-certificates tar xz-utils fzf nginx ufw unattended-upgrades acl` | apt is naturally idempotent |
| `01-unattended-upgrades.sh` | enable automatic security updates | check config before write |
| `10-user-sshd.sh` | assert user `ib` (groups `sudo,adm`, NOPASSWD sudo, locked password, zsh shell, authorized key); write `/etc/ssh/sshd_config.d/60-ib-hardening.conf` (Port 42318, pubkey-only, `AllowUsers ib`, no root); restart ssh | user exists / file content compare |
| `20-shell.sh` | oh-my-zsh, powerlevel10k, zsh-syntax-highlighting; clone `yet-an-other/dotfiles`; symlink `.zshrc`, `.p10k.zsh` | `[ ! -d …/.git ]` (existing pattern) |
| `21-fonts.sh` | JetBrainsMono Nerd Font → `~/.local/share/fonts`, `fc-cache` | archive presence / reinstall-safe |
| `30-editor.sh` | neovim latest tarball → `/opt/nvim-linux-<arch>`, symlink `/usr/local/bin/nvim`; LazyVim starter; keymaps.lua symlink from dotfiles | version/arch detection |
| `31-tools.sh` | eza (apt or latest `.deb` by arch, existing `install_eza` pattern); zmx tarball by arch → `/usr/local/bin`; zmx-select.sh session picker → `/opt/zmx-select.sh` | `command -v` / version check; file content compare |

`10-user-sshd.sh` re-asserts what user-data already did minimally — intentional: user-data is a
bootstrap shim (§7), the unit is the contract.

## 5. VPN layer units (#5, #7)

| Unit | Does |
|---|---|
| `40-xray.sh` | run `lib/install-xray.sh` (install/upgrade xray-core, systemd unit); logrotate for `/var/log/xray/*.log`; `systemctl enable --now xray` / restart on config change |
| `41-nginx.sh` | place rendered `nginx.conf` / `conf.d/default.conf` / `conf.d/fallback.conf` / `conf.d/xform.conf`; `nginx -t`; reload |
| `42-ufw.sh` | `default deny incoming`, `default allow outgoing`; allow `42318/tcp` (SSH), `443/tcp` (VPN), and `9443/tcp` (xform); `--force enable`. **443/udp stays closed deliberately** (QUIC blocked, §6) |
| `43-xform.sh` | install the latest stable checksum-verified xform release by architecture; place and harden its systemd service; preserve state; smoke-test updates; roll back and quarantine failed releases |

The xray config and nginx confs are rendered by the play (§9) from `templates/` before units run;
units never template — they place, verify, restart. Unit 43 is also invoked on otherwise unchanged Ansible
runs so release discovery happens during every deliberate deployment, never from a background timer.

## 6. xray configuration (#3, #7)

Rolled out in slices: #10 + #13 landed the inbound (127.0.0.1:20001 behind the
nginx SNI map, `dest` = the local fallback vhost); #11 chained the catch-all via
alwyzon; #12 landed the full routing table below (bastion outbound, privileged
split, blocked rule; freedom kept last, unused, for debugging). `dest` must
always be a live TLS 1.3 endpoint — xray mirrors dest's handshake even for
authenticated clients (post-mortem in #10).

Template: `templates/xray-config.json.j2` → `/usr/local/etc/xray/config.json`.

**Panel gRPC API.** xform's prerequisite contract enables `stats`, level-zero user uplink,
downlink, and online-user policy, plus inbound/outbound system traffic policy. Xray exposes
`StatsService` and `HandlerService` at `127.0.0.1:8080`. HandlerService lets xform push roster changes
to the running xray process without a restart; RoutingService, LoggerService, and all other services
remain disabled. The loopback boundary is mandatory because Xray's gRPC API has no authentication or
TLS. Existing user email tags are the per-user statistics identities.

**Inbound** (single live inbound; the nginx SNI map anticipates more — see fog):

```json
{
  "tag": "vless-reality",
  "listen": "127.0.0.1",
  "port": 20001,
  "protocol": "vless",
  "settings": {
    "clients": [
      { "id": "<user.uuid>", "flow": "xtls-rprx-vision", "email": "<user.name>" }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "sockopt": { "acceptProxyProtocol": true },
    "realitySettings": {
      "show": false,
      "dest": "127.0.0.1:8443",
      "xver": 1,
      "serverNames": ["{{ forpost.server_name }}"{% if forpost.backup_domain is defined %}, "{{ forpost.backup_domain }}"{% endif %}],
      "privateKey": "{{ forpost.private_key }}",
      "shortIds": {{ forpost.short_ids | to_json }}
    }
  },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls"], "routeOnly": true }
}
```

**PROXY protocol, both hops.** The nginx stream server sends PROXY protocol v1 to its upstreams, so
the inbound sets `sockopt.acceptProxyProtocol` and xray attributes connections to the real client
address instead of `127.0.0.1`; `realitySettings.xver: 1` sends PROXY v1 on to the dest, where the
fallback vhost restores the real address. Both pairs must stay in lockstep — a one-sided flip drops
every connection or kills dest mirroring (#10) — so the play runs `tests/proxy-protocol.sh` (renders
the templates with fixtures, asserts each directive and the pairwise consistency) after rendering and
before any unit places a config.

**Outbounds** (order matters — alwyzon first, defense-in-depth):

1. `alwyzon`: vless client to `forpost.alwyzon.*` — `encryption: "none"` (explicit), `flow:
   xtls-rprx-vision`, `streamSettings`: tcp + reality (`serverName`, `fingerprint: chrome`,
   `publicKey`, `shortId`). Field name note: newer xray renames outbound `publicKey` → `password`;
   match the pinned xray version (`docs/research/xray-vlessroute.md` Q4).
2. `bastion`: same shape from `forpost.bastion.*`. The outbound dials with the
   group-3 `0001` marker derived from the registered UUID — bastion's `vlessRoute: "1"`
   rule gates internal-IP routing on that marker (wg-in); auth ignores group 3
   (`docs/research/xray-vlessroute.md` Q1).
3. `blocked`: `blackhole`, `settings.response.type: "none"`.
4. `dns-internal`: Xray's `dns` outbound. It feeds privileged clients' intercepted A/AAAA
   queries into the built-in split-horizon DNS module.
5. `direct`: `freedom`, deliberately unused and last (debugging aid).

**Routing** (top-to-bottom, first match; `domainStrategy: "AsIs"`):

```json
"rules": [
  { "type": "field", "inboundTag": ["dns-query"], "ip": ["192.168.30.1/32"], "outboundTag": "bastion" },
  { "type": "field", "inboundTag": ["dns-query"],                                 "outboundTag": "alwyzon" },
  { "type": "field", "user": [<privileged names>], "port": "53", "network": "udp,tcp", "outboundTag": "dns-internal" },
  { "type": "field", "user": [<privileged names>], "domain": ["domain:bdgn.me"],   "outboundTag": "bastion" },
  { "type": "field", "user": [<privileged names>], "ip": ["192.168.0.0/16"],        "outboundTag": "bastion" },
  { "type": "field",                                 "ip": ["192.168.0.0/16"],        "outboundTag": "blocked" },
  { "type": "field",                                 "network": "tcp,udp",            "outboundTag": "alwyzon" }
]
```

`<privileged names>` = `forpost.users | selectattr('privileged') | map(attribute='name')`.
The template asserts at render time: every user has `name` + `uuid`; names unique (the play
validates uniqueness before render; the template enforces the per-user fields via `mandatory`).

**DNS override.** For privileged authenticated users, any traditional DNS request carried by
the tunnel (UDP/TCP port 53, regardless of whether the client addressed 1.1.1.1, 8.8.8.8, etc.)
is intercepted by `dns-internal`. The built-in DNS module sends `domain:bdgn.me` to
`192.168.30.1` with `skipFallback: true`; its tagged query routes via the marked bastion outbound.
Other names use `1.1.1.1` via alwyzon. Non-privileged clients bypass the override. Xray 26.3.27's
DNS outbound uses the legacy `nonIPQuery` settings and resolves A/AAAA through the module; the
newer documented `rewriteAddress`/`rules` fields are silently ignored by this pinned build.
Ordinary proxied domains are still resolved by bastion or alwyzon.

**UDP policy**: `xtls-rprx-vision` blocks UDP/443 (QUIC) deliberately — clients fall back to TCP.
No Mux server-side.

## 7. nginx configuration (#7)

Full frontgate arrangement (`frontgate/` is the reference implementation), with vless-reality as the
only live inbound. Template files:

- `nginx.conf.j2` — http block (includes `conf.d`) + **stream block**: `listen 443`,
  `ssl_preread on`, `proxy_protocol on` (PROXY v1 to every upstream — see §6); SNI map:
  - `{{ forpost.server_name }}` → `127.0.0.1:20001` (xray)
  - `{{ forpost.backup_domain }}` → `127.0.0.1:20001` (same inbound; only when the optional
    `backup_domain` var is set — one node, two public names, same users)
  - `default` → `127.0.0.1:20000` (default site)
- `default.conf.j2` — TLS server on `127.0.0.1:20000`, `server_name _;`, `return 418;`
  (frontgate pattern; cert per below). Listens `proxy_protocol` (the stream default route sends it)
  and restores the real client address via `set_real_ip_from 127.0.0.1` + `real_ip_header
  proxy_protocol` — plain connections are rejected by design
- `fallback.conf.j2` — TLS server on `127.0.0.1:8443`, `server_name {{ forpost.server_name }}`
  (plus `{{ forpost.backup_domain }}` when set — the cert must cover every served name or the
  camouflage breaks for the extra one), reverse-proxies the **real** `https://speed.bdgn.me` (public, served by frontgate) so probes see a
  genuine site; preserve `Host` towards upstream per frontgate's fallback.conf conventions. Listens
  `proxy_protocol` (xray dials with `xver: 1`, §6) and restores the real client address, so
  `X-Real-IP`/`X-Forwarded-For` towards speed.bdgn.me carry the true client, not `127.0.0.1`
- `xform.conf.j2` — public TLS server on `9443`, `server_name {{ forpost.domain }}`, proxying the full
  origin to xform at `127.0.0.1:9090` with no URI rewrite. It deliberately adds no proxy authentication
  or source restriction; authentication belongs to xform and public pre-auth exposure is accepted.

**Certificate**: TLS cert for `{{ forpost.domain }}` via the existing
`ansible/add-ssl-certificate.yaml` (Cloudflare DNS challenge; `cf_token`/`cf_zone_id` already in
secrets), installed before `41-nginx.sh` runs. With `backup_domain` set, one SAN cert covers both
names (`docs/research/xray-multidomain.md`: one inbound serves both SNIs; a shared SAN cert also
publicly links the names via CT logs — two certs would be the unlinkable alternative). Used by the
fallback, default, and xform sites.
Note: this is cert issuance only — the DNS *A record* stays manual (§10).

### xform lifecycle (#14)

xform runs as a dedicated unprivileged user under a hardened systemd service. Its HTTP listener is
`127.0.0.1:9090`; environment variables point it at the loopback xray API, Xray config, persistent
state, and `xray.service`. A file ACL grants config read access, while a directory ACL and the unit's
`ReadWritePaths=/usr/local/etc/xray` exception allow atomic roster rewrites without granting root. A
default ACL preserves read access for xray's `nobody` user when xform replaces the mode-0640 config.
xform can write only its systemd-managed application state and the Xray config directory. Installed
release metadata, the quarantine marker, and the pre-upgrade database backup stay in root-owned
forpost deployment state.

Every normal Ansible deployment asks GitHub for the latest stable, non-draft, non-prerelease release,
selects `xform-linux-amd64` or `xform-linux-arm64`, and verifies it against `checksums.txt`. Matching
content is a no-op. Updates download and verify while the old process remains live, then stop xform,
retain the previous binary and one database backup, swap atomically, restart, and probe `/api/v1/healthz`, falling back to the current
`/api/v1/server` contract when healthz is not implemented. Either release-appropriate endpoint is a
successful smoke test; exposing neither rejects the release. Release tags, not asset hashes, define upgrade identity:
the same tag is a no-op, while a new tag is restarted and smoke-tested even when its bytes are identical.
A failed probe restores the binary and database, restarts the prior version, and records the rejected tag.
A healthy rollback is a recovered update, so the play continues to its Xray, nginx, and port-443 checks;
the same rejected tag is skipped until a newer release
appears or `/var/lib/forpost/xform/rejected-version` is removed manually. Inspect service and update output with
`journalctl -u xform` and `/var/log/forpost/43-xform.log`.

If release discovery or download fails before first installation, deployment fails. If a verified xform
is already installed, the unit warns, retains it, and verifies local health. The upstream daily update
timer is never installed. A brief `9443` outage during update is accepted; port `443` and the VPN data
path are never restarted by the xform unit.

**user-data.yaml** (slim, reachability-only — the whole contract):

```yaml
#cloud-config
users:
  - name: ib
    groups: [sudo, adm]
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    shell: /usr/bin/zsh
    ssh_authorized_keys:
      - <the repo's ib key, as in cloud-init/cloud-init-ubuntu.yaml>
disable_root: true
ssh_pwauth: false
packages: [zsh]
write_files:
  - path: /etc/ssh/sshd_config.d/60-ib-hardening.conf
    content: |
      Port 42318
      PermitRootLogin no
      PasswordAuthentication no
      PubkeyAuthentication yes
      AllowUsers ib
runcmd:
  - systemctl restart ssh
```

No repo clone, no credentials, no script embedding — Ansible delivers everything else.

## 8. Client contract (#7)

Per user, a share link (distribution mechanism is fog):

```
vless://<uuid>@<domain>:443?security=reality&sni=<server_name>&fp=chrome&pbk=<reality-pubkey>&sid=<short-id>&flow=xtls-rprx-vision&type=tcp#<name>
```

`pbk` derived from `forpost.private_key` via `xray x25519 -i`. UUIDs are plain v4 — no marker semantics.
With `backup_domain` set, the same UUID/`pbk`/`sid` links work verbatim against
`<backup_domain>` (`sni=<backup_domain>`) — one user set, two entry names.

**Client DNS (split horizon).** `*.bdgn.me` is a split-horizon zone: internal-only names
(`syncthing`, `s3`, `speed-test`, …) exist ONLY on the internal resolver `192.168.30.1` — public
resolvers NXDOMAIN them, and public-record names resolve to frontgate's public entry. For a
privileged client whose traditional DNS traffic traverses the VPN, forpost transparently
intercepts UDP/TCP port 53 and resolves `bdgn.me` through `192.168.30.1`; the configured resolver
address (1.1.1.1, 8.8.8.8, etc.) therefore does not matter. The override cannot intercept encrypted
DNS (DoH/DoT/DoQ on 443/853) or DNS deliberately sent outside the VPN. Such clients must disable
Private/Encrypted DNS or set their remote/VPN DNS to `192.168.30.1`. Non-privileged users retain
their configured public resolver and still cannot reach internal IPs. Clients that pass domains
through the tunnel (socks5h-style) use bastion's scoped internal DNS module instead.

## 9. The play: `create-forpost.yaml` (#6)

`hosts: forpost` (the secret-inventory host entry). Run via `./apply.sh forpost` — unchanged.

1. `wait_for_connection` (port 42318 per inventory)
2. cert for `forpost.domain` via `import_tasks: ../ansible/add-ssl-certificate.yaml`
3. push `bootstrap.sh` + `units/` → `/usr/local/sbin/forpost/` (mode 0755)
4. render `templates/xray-config.json.j2` → `/usr/local/etc/xray/config.json`
5. render `templates/{nginx.conf,default.conf,fallback.conf}.j2` → staging under `/usr/local/sbin/forpost/nginx/`
6. render the xform nginx vhost and hardened systemd service into staging
7. nginx first: `bootstrap.sh --only 41` brings the fallback vhost up BEFORE any xray restart — xray
   mirrors dest's handshake even for authenticated clients, so xray-first ordering drops clients (#10)
8. command: `/usr/local/sbin/forpost/bootstrap.sh` (full run; `--from 40` when iterating on the VPN layer)
9. run `bootstrap.sh --only 43` after orchestration on every apply to check the latest stable xform
   release without touching Xray or nginx (a preceding full bootstrap makes this an immediate no-op)
10. verify: public ports 443 and 9443, active/enabled xray+nginx+xform, loopback-only xform and xray API,
    bounded xform roster access, and exact UFW lockdown (42318 + 443 + 9443/tcp)

Re-running the play on a live node must be a no-op when configuration and the latest xform release are
unchanged (idempotency, #5).

## 10. Runbook

**First deploy**

1. Create an Ubuntu VM (x86_64 or arm64) at any provider; paste `forpost/user-data.yaml` as user-data
2. Manual A record: `forpost.domain` → VM IP (Cloudflare automation is fog); with `backup_domain`
   set, an A record for it → the same VM IP
3. Generate key material (§3 commands); fill the `forpost` host entry + vars section in
   `inventory.secret.yaml`
4. **Upstream clients**: add forpost's client UUID to bastion's xray clients (`vm-bastion/`) and to
   alwyzon's xray (manual — external VM); record coordinates in the vars section
5. Open TCP port `9443` in the cloud-provider firewall (provider firewall automation remains out of scope)
6. `./apply.sh forpost`

**Re-run / iterate**: `./apply.sh forpost` (no-op when unchanged); to re-run only the VPN layer,
`ansible-playbook … -e "forpost_bootstrap_args='--from 40'"` (inner quotes keep the
argument intact — the unquoted form reaches bootstrap.sh as a bare `--from`). PROXY protocol
deploys flip both ends of a pair in one run (nginx via the play's `--only 41` pre-step, xray in unit
40); new connections can fail for the seconds between the two flips — unavoidable for a coordinated
switchover, and healed as soon as 40 completes.

## 11. Verification checklist

- [ ] `ssh -p 42318 ib@<domain>` works; root/password auth refused
- [ ] `systemctl is-active xray nginx xform` all active; UFW shows only 42318 + 443 + 9443/tcp
- [ ] `curl -sv https://<domain>/` serves the real speed.bdgn.me content (fallback)
- [ ] probe with wrong SNI → 418
- [ ] loopback sites speak PROXY protocol only: `tests/proxy-protocol.sh` is green; a plain (no-PP)
      connection to `127.0.0.1:20000`/`:8443` is refused, while `curl https://<domain>/` through 443
      still serves the fallback content (both PP hops live)
- [ ] `/var/log/nginx/fallback.access.log` records real client addresses (not `127.0.0.1`)
- [ ] `curl -fsS https://<domain>:9443/` reaches xform with a valid certificate
- [ ] xform listens only on `127.0.0.1:9090`; Xray StatsService and HandlerService listen only on `127.0.0.1:8080`
- [ ] `xray api statsquery --server=127.0.0.1:8080` succeeds
- [ ] non-privileged client: exit IP = alwyzon's; public `*.bdgn.me` works; `192.168.x.x` fails fast
- [ ] privileged client: exit IP = alwyzon's; `*.bdgn.me` and internal IPs reach internal VMs via bastion
- [ ] second `./apply.sh forpost` run reports no changes when upstream has no newer xform release

## 12. Non-goals / fog

Out of scope (map #2): cloud VM provisioning; alwyzon configuration-as-code; frontgate/front-door changes.
Not yet specified: client onboarding/distribution; observability beyond xform deployment (alerting and
telemetry semantics remain upstream concerns); multi-node orchestration; additional VLESS transports (xhttp, tcp+tls — the SNI map anticipates them); Cloudflare
DNS-record automation.
