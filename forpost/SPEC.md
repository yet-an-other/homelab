# forpost — cloud VPN entry node

Status: **created**. 
([issue #2](https://github.com/yet-an-other/homelab/issues/2)) and its resolved tickets
([#3](https://github.com/yet-an-other/homelab/issues/3),
[#5](https://github.com/yet-an-other/homelab/issues/5),
[#6](https://github.com/yet-an-other/homelab/issues/6),
[#7](https://github.com/yet-an-other/homelab/issues/7)).
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
```

Privilege is enforced by the **authenticated email tag** in xray (`user` field in routing rules).
vlessRoute was evaluated and rejected: markers are unauthenticated and add a per-connection toggle
nobody needs (#3, #7). UUIDs are plain v4.

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
│   └── 42-ufw.sh
├── templates/
│   ├── xray-config.json.j2
│   ├── nginx.conf.j2
│   ├── default.conf.j2
│   └── fallback.conf.j2
└── user-data.yaml           # slim reachability-only cloud-init, pasted at VM creation
```

Principles: bash units do the work; Ansible renders secrets into templates and transports; every unit
is idempotent and individually re-runnable; plays never generate key material; download units are
arch-aware via `dpkg --print-architecture` (x86_64 primary, arm64 supported).

`bootstrap.sh`: `set -euo pipefail`; runs `units/[0-9][0-9]-*.sh` in order; supports
`--only <NN|name>` and `--from <NN>` for iteration; logs per-unit to `/var/log/forpost/`.

Staging path on the node: `/usr/local/sbin/forpost/` (bootstrap + units), templates rendered by the
play directly to their final destinations (xray config, nginx confs) before the corresponding unit runs.

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
| `00-packages.sh` | `apt-get update/upgrade`; install `sudo zsh btop curl openssl git gcc unzip zip jq fontconfig ca-certificates tar xz-utils fzf nginx ufw unattended-upgrades` | apt is naturally idempotent |
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
| `41-nginx.sh` | place rendered `nginx.conf` / `conf.d/default.conf` / `conf.d/fallback.conf`; `nginx -t`; reload |
| `42-ufw.sh` | `default deny incoming`, `default allow outgoing`; allow `42318/tcp` (SSH) and `443/tcp` only; `--force enable`. **443/udp stays closed deliberately** (QUIC blocked, §6) |

The xray config and nginx confs are rendered by the play (§9) from `templates/` before units run;
units never template — they place, verify, restart.

## 6. xray configuration (#3, #7)

Rolled out in slices: #10 ships the inbound (listening on public 443 as an
interim — #13 moves it to 127.0.0.1:20001 behind the nginx SNI map) plus a
freedom catch-all (direct to the wild); the upstream outbounds and rules
below land in #11 (alwyzon) and #12 (bastion split).

Template: `templates/xray-config.json.j2` → `/usr/local/etc/xray/config.json`.

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
    "realitySettings": {
      "show": false,
      "dest": "127.0.0.1:8443",
      "serverNames": ["{{ forpost.server_name }}"],
      "privateKey": "{{ forpost.private_key }}",
      "shortIds": {{ forpost.short_ids | to_json }}
    }
  },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls"], "routeOnly": true }
}
```

**Outbounds** (order matters — alwyzon first, defense-in-depth):

1. `alwyzon`: vless client to `forpost.alwyzon.*` — `encryption: "none"` (explicit), `flow:
   xtls-rprx-vision`, `streamSettings`: tcp + reality (`serverName`, `fingerprint: chrome`,
   `publicKey`, `shortId`). Field name note: newer xray renames outbound `publicKey` → `password`;
   match the pinned xray version (`docs/research/xray-vlessroute.md` Q4).
2. `bastion`: same shape from `forpost.bastion.*`.
3. `blocked`: `blackhole`, `settings.response.type: "none"`.

**Routing** (top-to-bottom, first match; `domainStrategy: "AsIs"`):

```json
"rules": [
  { "type": "field", "user": [<privileged names>], "domain": ["domain:bdgn.me"],   "outboundTag": "bastion" },
  { "type": "field", "user": [<privileged names>], "ip": ["192.168.0.0/16"],        "outboundTag": "bastion" },
  { "type": "field",                                 "ip": ["192.168.0.0/16"],        "outboundTag": "blocked" },
  { "type": "field",                                 "network": "tcp,udp",            "outboundTag": "alwyzon" }
]
```

`<privileged names>` = `forpost.users | selectattr('privileged') | map(attribute='name')`.
The template asserts at render time: every user has `name` + `uuid`; names unique.

**No `dns` module.** Domain rules match by name; bastion resolves `bdgn.me` internally
(its existing config already does, via 192.168.30.1), alwyzon resolves the rest.

**UDP policy**: `xtls-rprx-vision` blocks UDP/443 (QUIC) deliberately — clients fall back to TCP.
No Mux server-side.

## 7. nginx configuration (#7)

Full frontgate arrangement (`frontgate/` is the reference implementation), with vless-reality as the
only live inbound. Template files:

- `nginx.conf.j2` — http block (includes `conf.d`) + **stream block**: `listen 443`,
  `ssl_preread on`; SNI map:
  - `{{ forpost.server_name }}` → `127.0.0.1:20001` (xray)
  - `default` → `127.0.0.1:20000` (default site)
- `default.conf.j2` — TLS server on `127.0.0.1:20000`, `server_name _;`, `return 418;`
  (frontgate pattern; cert per below)
- `fallback.conf.j2` — TLS server on `127.0.0.1:8443`, `server_name {{ forpost.server_name }};`,
  reverse-proxies the **real** `https://speed.bdgn.me` (public, served by frontgate) so probes see a
  genuine site; preserve `Host` towards upstream per frontgate's fallback.conf conventions

**Certificate**: TLS cert for `{{ forpost.domain }}` via the existing
`ansible/add-ssl-certificate.yaml` (Cloudflare DNS challenge; `cf_token`/`cf_zone_id` already in
secrets), installed before `41-nginx.sh` runs. Used by both the fallback vhost and the default site.
Note: this is cert issuance only — the DNS *A record* stays manual (§10).

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

## 9. The play: `create-forpost.yaml` (#6)

`hosts: forpost` (the secret-inventory host entry). Run via `./apply.sh forpost` — unchanged.

1. `wait_for_connection` (port 42318 per inventory)
2. cert for `forpost.domain` via `import_tasks: ../ansible/add-ssl-certificate.yaml`
3. push `bootstrap.sh` + `units/` → `/usr/local/sbin/forpost/` (mode 0755)
4. render `templates/xray-config.json.j2` → `/usr/local/etc/xray/config.json`
5. render `templates/{nginx.conf,default.conf,fallback.conf}.j2` → staging under `/etc/nginx/`
6. command: `/usr/local/sbin/forpost/bootstrap.sh` (full run; `--from 40` when iterating on the VPN layer)
7. verify: `wait_for port 443`, `systemctl is-active xray nginx`

Re-running the play on a live node must be a no-op when nothing changed (idempotency, #5).

## 10. Runbook

**First deploy**

1. Create an Ubuntu VM (x86_64 or arm64) at any provider; paste `forpost/user-data.yaml` as user-data
2. Manual A record: `forpost.domain` → VM IP (Cloudflare automation is fog)
3. Generate key material (§3 commands); fill the `forpost` host entry + vars section in
   `inventory.secret.yaml`
4. **Upstream clients**: add forpost's client UUID to bastion's xray clients (`vm-bastion/`) and to
   alwyzon's xray (manual — external VM); record coordinates in the vars section
5. `./apply.sh forpost`

**Re-run / iterate**: `./apply.sh forpost` (no-op when unchanged); to re-run only the VPN layer,
`ansible-playbook … -e forpost_bootstrap_args="--from 40"`.

## 11. Verification checklist

- [ ] `ssh -p 42318 ib@<domain>` works; root/password auth refused
- [ ] `systemctl is-active xray nginx` both active; `ufw status` shows only 42318 + 443/tcp
- [ ] `curl -sv https://<domain>/` serves the real speed.bdgn.me content (fallback)
- [ ] probe with wrong SNI → 418
- [ ] non-privileged client: exit IP = alwyzon's; public `*.bdgn.me` works; `192.168.x.x` fails fast
- [ ] privileged client: exit IP = alwyzon's; `*.bdgn.me` and internal IPs reach internal VMs via bastion
- [ ] second `./apply.sh forpost` run reports no changes

## 12. Non-goals / fog

Out of scope (map #2): cloud VM provisioning; alwyzon configuration-as-code; frontgate/front-door changes.
Not yet specified: client onboarding/distribution; observability (log retention, alerting); multi-node
orchestration; additional VLESS transports (xhttp, tcp+tls — the SNI map anticipates them); Cloudflare
DNS-record automation.
