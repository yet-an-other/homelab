#!/bin/bash
#
# genkeys.sh — print a ready-to-paste `forpost` vars block for
# ansible/inventory.secret.yaml (SPEC §3), plus the client share links (SPEC §8).
#
# Key material is human-generated once and pasted in — this helper just saves
# the typing. Requires a local xray binary (brew install xray, or
# https://github.com/XTLS/Xray-install).
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: genkeys.sh [domain]

Prints a ready-to-paste `forpost` vars block for ansible/inventory.secret.yaml
(SPEC §3) plus the client share links (SPEC §8). `domain` defaults to
fp1.bdgn.me. Requires a local xray binary.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

if [ "$#" -gt 1 ]; then
  echo "error: unexpected arguments: ${*:2}" >&2
  usage >&2
  exit 2
fi

if ! command -v xray >/dev/null 2>&1; then
  echo "error: 'xray' not found; install it first (brew install xray or the official installer)." >&2
  exit 1
fi

last_field() { awk '{print $NF}'; }

KEYPAIR="$(xray x25519)"
PRIVATE_KEY="$(printf '%s\n' "${KEYPAIR}" | grep -i '^private' | last_field)"
PUBLIC_KEY="$(printf '%s\n' "${KEYPAIR}" | grep -iE '^(public|password)' | last_field)"

if [ -z "${PRIVATE_KEY}" ] || [ -z "${PUBLIC_KEY}" ]; then
  echo "error: could not parse 'xray x25519' output:" >&2
  printf '%s\n' "${KEYPAIR}" >&2
  exit 1
fi

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-F' 'a-f'
  else
    xray uuid
  fi
}

UUID_ADMIN="$(new_uuid)"
UUID_MOM="$(new_uuid)"

DOMAIN="${1:-fp1.bdgn.me}"

cat <<EOF
# --- paste into the vpn group vars in ansible/inventory.secret.yaml ---
    forpost:
      domain: ${DOMAIN}              # node public name; manual A record -> ansible_host
      server_name: ${DOMAIN}         # Reality SNI; normally == domain
      private_key: ${PRIVATE_KEY}
      short_ids: ["01", "02"]
      users:
        - { name: admin, uuid: ${UUID_ADMIN}, privileged: true }
        - { name: mom,   uuid: ${UUID_MOM}, privileged: false }
      alwyzon:                       # forpost's CLIENT credentials on alwyzon's xray
        address: <alwyzon-host>
        port: 443
        uuid: <uuid>
        server_name: <alwyzon-reality-sni>
        public_key: <alwyzon-x25519-pub>
        short_id: "01"
      bastion:                       # forpost's CLIENT credentials on bastion's xray
        address: <externally-reachable bastion xray endpoint>
        port: 443
        uuid: <uuid>
        server_name: <bastion-reality-sni>
        public_key: <bastion-x25519-pub>
        short_id: "01"

# --- client share links (SPEC §8) ---
vless://${UUID_ADMIN}@${DOMAIN}:443?security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=01&flow=xtls-rprx-vision&type=tcp#admin
vless://${UUID_MOM}@${DOMAIN}:443?security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=01&flow=xtls-rprx-vision&type=tcp#mom
EOF
