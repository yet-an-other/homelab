#!/bin/bash
#
# xform-connections.sh — the panel advertisement contract across forpost's
# templates.
#
# Renders xform-connections.json.j2 + xray-config.json.j2 + xform.service.j2
# with fixture vars and asserts the advertised connection settings satisfy
# the xray inbound they select (upstream xform SPEC §3.2 `direct` rules),
# and that the service unit points XFORM_CONNECTIONS_CONFIG at the exact
# path the play renders:
#
#   advertisement.inbound_tag      == xray inbound tag
#   transport/security type         == inbound canonical network/security
#   security.server_name            ∈ inbound realitySettings.serverNames
#   security.short_id               ∈ inbound shortIds
#   host/port                       == the public nginx entry (domain:443)
#   unit XFORM_CONNECTIONS_CONFIG   == /usr/local/etc/xform/connections.json
#
# Like the PROXY protocol pairs these are cross-template contracts: a
# mismatched advertisement makes the panel mark the profile
# `inbound_mismatch` and the client link disappears; an env var aimed at a
# path nothing renders serves `source_unavailable` forever. Both drift
# silently without this check.
#
# Exit 0 = consistent, exit 1 = RED (printed), exit 2 = harness failure.
# (No `set -e`: failures are accumulated and reported together.)
#
# Usage: tests/xform-connections.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
failures=0

cleanup() { rm -rf "${tmp}"; }
trap cleanup EXIT

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

pass() {
  echo "PASS: $*"
}

command -v ansible >/dev/null || { echo "ansible not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

# Fixture: every var the templates mandate (§3 shape, throwaway values).
cat >"${tmp}/fixture.json" <<'EOF'
{
  "forpost": {
    "domain": "fp1.example.net",
    "server_name": "fp1.example.net",
    "private_key": "fixture-private-key",
    "public_key": "fixture-public-key-base64url-43-characters-x",
    "short_ids": ["01", "02"],
    "users": [
      { "name": "admin", "uuid": "11111111-1111-4111-8111-111111111111", "privileged": true },
      { "name": "guest", "uuid": "22222222-2222-4222-8222-222222222222", "privileged": false }
    ],
    "xform_password": "fixture-panel-password",
    "alwyzon": {
      "address": "a.example.net", "port": 443, "uuid": "33333333-3333-4333-8333-333333333333",
      "server_name": "a.example.net", "public_key": "fixture-pub", "short_id": "01"
    },
    "bastion": {
      "address": "b.example.net", "port": 443, "uuid": "44444444-4444-4444-8444-444444444444",
      "server_name": "b.example.net", "public_key": "fixture-pub", "short_id": "01"
    }
  }
}
EOF

render() {
  local src="$1" dest="$2" fx="${3:-${tmp}/fixture.json}"
  ansible localhost, -c local -m template \
    -a "src=${here}/templates/${src} dest=${dest}" \
    -e "@${fx}" >/dev/null 2>&1 || { echo "render ${src} failed" >&2; exit 2; }
}

render xform-connections.json.j2 "${tmp}/connections.json"
render xray-config.json.j2 "${tmp}/xray-config.json"
render xform.service.j2 "${tmp}/xform.service"

# --- connections file parses and has the strict root shape ---------------------
jq . "${tmp}/connections.json" >/dev/null 2>&1 ||
  { echo "rendered connections file is not valid JSON" >&2; exit 2; }

if [ "$(jq -r '.version' "${tmp}/connections.json")" = "1" ] &&
  [ "$(jq '.advertisements | length' "${tmp}/connections.json")" = "1" ]; then
  pass "root shape: version 1, exactly one advertisement"
else
  fail "root shape must be version 1 with exactly one advertisement"
fi

ad_tag="$(jq -r '.advertisements[0].inbound_tag' "${tmp}/connections.json")"
inbound_tag="$(jq -r '.inbounds[] | select(.protocol == "vless") | .tag' "${tmp}/xray-config.json")"
if [ -n "${inbound_tag}" ] && [ "${ad_tag}" = "${inbound_tag}" ]; then
  pass "advertisement selects the live inbound tag (${ad_tag})"
else
  fail "advertisement tag '${ad_tag}' matches no xray inbound ('${inbound_tag}') — the panel would warn and drop the profile"
fi

host="$(jq -r '.advertisements[0].host' "${tmp}/connections.json")"
port="$(jq -r '.advertisements[0].port' "${tmp}/connections.json")"
topology="$(jq -r '.advertisements[0].topology' "${tmp}/connections.json")"
if [ "${topology}" = "direct" ] && [ "${host}" = "fp1.example.net" ] && [ "${port}" = "443" ]; then
  pass "direct advertisement carries the public nginx entry (domain:443)"
else
  fail "topology/host/port are '${topology}'/'${host}'/'${port}', want direct/fp1.example.net/443"
fi

# --- direct topology: the advertisement must satisfy the inbound ----------------
ad_network="$(jq -r '.advertisements[0].transport.type' "${tmp}/connections.json")"
in_network="$(jq -r '.inbounds[] | select(.tag == "vless-reality") | .streamSettings.network' "${tmp}/xray-config.json")"
if [ "${ad_network}" = "${in_network}" ]; then
  pass "transport type equals the inbound network (${ad_network})"
else
  fail "transport '${ad_network}' != inbound network '${in_network}' — panel marks inbound_mismatch"
fi

ad_security="$(jq -r '.advertisements[0].security.type' "${tmp}/connections.json")"
in_security="$(jq -r '.inbounds[] | select(.tag == "vless-reality") | .streamSettings.security' "${tmp}/xray-config.json")"
if [ "${ad_security}" = "${in_security}" ]; then
  pass "security type equals the inbound security (${ad_security})"
else
  fail "security '${ad_security}' != inbound security '${in_security}' — panel marks inbound_mismatch"
fi

ad_sni="$(jq -r '.advertisements[0].security.server_name' "${tmp}/connections.json")"
if jq -e --arg sni "${ad_sni}" '.inbounds[] | select(.tag == "vless-reality")
    | .streamSettings.realitySettings.serverNames | index($sni)' \
  "${tmp}/xray-config.json" >/dev/null; then
  pass "advertised server_name is accepted by the inbound (${ad_sni})"
else
  fail "advertised server_name '${ad_sni}' is not in the inbound serverNames — panel marks inbound_mismatch"
fi

ad_sid="$(jq -r '.advertisements[0].security.short_id' "${tmp}/connections.json")"
if jq -e --arg sid "${ad_sid}" '.inbounds[] | select(.tag == "vless-reality")
    | .streamSettings.realitySettings.shortIds | index($sid)' \
  "${tmp}/xray-config.json" >/dev/null; then
  pass "advertised short_id is accepted by the inbound (${ad_sid})"
else
  fail "advertised short_id '${ad_sid}' is not in the inbound shortIds — panel marks inbound_mismatch"
fi

if [ "$(jq -r '.advertisements[0].security.public_key | length' "${tmp}/connections.json")" -gt 0 ] &&
  [ "$(jq -r '.advertisements[0].security.fingerprint' "${tmp}/connections.json")" = "chrome" ]; then
  pass "REALITY public_key present and fingerprint chrome (SPEC §8 link shape)"
else
  fail "advertisement must carry a non-empty public_key and fingerprint chrome"
fi

# --- pair: the env var must aim at the path the play renders --------------------
if grep -q '^Environment=XFORM_CONNECTIONS_CONFIG=/usr/local/etc/xform/connections.json$' "${tmp}/xform.service"; then
  pass "pair: unit XFORM_CONNECTIONS_CONFIG ⟺ rendered connections.json path"
else
  fail "pair broken: xform.service must set XFORM_CONNECTIONS_CONFIG=/usr/local/etc/xform/connections.json — any other path serves source_unavailable forever"
fi

# --- optional backup domain (SPEC §3/§6): the advertisement stays primary-only --
# Upstream rejects duplicate inbound tags, so the panel can advertise only
# one host per inbound — the primary. The backup name must NOT leak into
# the advertisement, and the primary SNI must remain accepted now that the
# inbound serves both names.
fixture2="${tmp}/fixture-backup.json"
jq '.forpost.backup_domain = "fp2.example.net"' "${tmp}/fixture.json" >"${fixture2}"

render xform-connections.json.j2 "${tmp}/connections-backup.json" "${fixture2}"
render xray-config.json.j2 "${tmp}/xray-backup.json" "${fixture2}"

backup_host="$(jq -r '.advertisements[0].host' "${tmp}/connections-backup.json")"
if [ "${backup_host}" = "fp1.example.net" ] &&
  ! grep -q "fp2.example.net" "${tmp}/connections-backup.json"; then
  pass "backup: advertisement stays primary-name only"
else
  fail "backup: advertisement host is '${backup_host}' — the panel advertises exactly the primary entry"
fi

backup_sni="$(jq -r '.advertisements[0].security.server_name' "${tmp}/connections-backup.json")"
if jq -e --arg sni "${backup_sni}" '.inbounds[] | select(.tag == "vless-reality")
    | .streamSettings.realitySettings.serverNames | index($sni)' \
  "${tmp}/xray-backup.json" >/dev/null; then
  pass "backup: advertised server_name still accepted by the dual-name inbound"
else
  fail "backup: advertised server_name '${backup_sni}' rejected by the dual-name inbound"
fi

echo
if [ "${failures}" -gt 0 ]; then
  echo "RED: ${failures} check(s) failed"
  exit 1
fi
echo "GREEN: panel advertisement satisfies the inbound end to end"
