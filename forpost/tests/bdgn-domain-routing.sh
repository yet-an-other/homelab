#!/bin/bash
# e2e regression: privileged client sending a DOMAIN through the tunnel
# (mobile-client style, e.g. v2box) must reach internal *.bdgn.me services.
#
# Bug history: bastion had no `domain:bdgn.me -> wg-in` rule, so
# domain-targeted internal traffic fell to the `network: tcp,udp` catch-all
# -> wg-out -> ForceIP resolved the name to a 192.168/16 address via the
# (already fixed, ba2e13e) DNS module -> dialed an internal IP through the
# EXTERNAL wireguard -> silent timeout. Bare-IP access worked, which masked
# the bug for desktop clients resolving via forpost's DNS interception.
#
# RED  = curl times out (no HTTP code)
# GREEN = any HTTP response code within the timeout (403 from OPNsense is a
#         perfectly good green — we assert reachability, not auth)
#
# Usage:
#   bdgn-domain-routing.sh --uuid <privileged-user-uuid> --pbk <reality-pubkey> \
#       [--domain loft.bdgn.me] [--name os.bdgn.me] [--timeout 15]
#
# Secrets come from ansible/inventory.secret.yaml (forpost.users[privileged],
# pbk = `xray x25519 -i $private_key`). Nothing secret is stored here.

set -euo pipefail

DOMAIN="loft.bdgn.me"
NAME="os.bdgn.me"
TIMEOUT=15
SOCKS_PORT=18080
WORKDIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --uuid) UUID="$2"; shift 2 ;;
    --pbk) PBK="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${UUID:?--uuid is required}"
: "${PBK:?--pbk is required}"

cleanup() {
  [ -n "${XRAY_PID:-}" ] && kill "$XRAY_PID" 2>/dev/null || true
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

WORKDIR=$(mktemp -d)
cat > "$WORKDIR/client.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks-in", "listen": "127.0.0.1", "port": $SOCKS_PORT,
      "protocol": "socks", "settings": { "udp": true } }
  ],
  "outbounds": [
    { "tag": "forpost", "protocol": "vless",
      "settings": { "address": "$DOMAIN", "port": 443, "id": "$UUID",
                    "encryption": "none", "flow": "xtls-rprx-vision" },
      "streamSettings": { "network": "tcp", "security": "reality",
        "realitySettings": { "serverName": "$DOMAIN", "fingerprint": "chrome",
                             "password": "$PBK", "shortId": "01" } } }
  ],
  "routing": { "domainStrategy": "AsIs",
    "rules": [ { "type": "field", "network": "tcp,udp", "outboundTag": "forpost" } ] }
}
EOF

xray run -c "$WORKDIR/client.json" > "$WORKDIR/xray.log" 2>&1 &
XRAY_PID=$!
sleep 2

CODE=$(curl -sk --max-time "$TIMEOUT" --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
  -o /dev/null -w "%{http_code}" "https://$NAME/" || true)

if [ "$CODE" = "000" ]; then
  echo "RED: domain-targeted https://$NAME/ did not answer within ${TIMEOUT}s"
  exit 1
fi

echo "GREEN: https://$NAME/ answered HTTP $CODE (domain passed through the tunnel)"
