#!/bin/bash
#
# proxy-protocol.sh — the PROXY protocol contract across forpost's templates.
#
# Renders nginx.conf / default.conf / fallback.conf / xray-config from the
# templates with fixture vars and asserts the full PROXY protocol chain is
# consistent (SPEC §6/§7):
#
#   client ──443──> nginx stream ──(PP v1)──> xray 20001 (acceptProxyProtocol)
#   xray reality ──(PP v1, xver:1)──> fallback 8443 (listen proxy_protocol)
#   nginx stream default ──(PP v1)──> default site 20000 (listen proxy_protocol)
#
# The pairwise checks matter more than any single directive: flipping one
# side of a pair (e.g. nginx sends PP but xray no longer accepts it, or xver
# set against a fallback that doesn't listen proxy_protocol) breaks either
# the whole VPN or Reality's dest mirroring (#10). Every loopback site must
# also restore the real client address (set_real_ip_from + real_ip_header)
# so logs and X-Forwarded-For carry it onward.
#
# Exit 0 = chain consistent, exit 1 = RED (printed), exit 2 = harness failure.
# (No `set -e`: failures are accumulated and reported together.)
#
# Usage: tests/proxy-protocol.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
fixture="${tmp}/fixture.json"
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
cat >"${fixture}" <<'EOF'
{
  "forpost": {
    "domain": "fp1.example.net",
    "server_name": "fp1.example.net",
    "private_key": "fixture-private-key",
    "short_ids": ["01", "02"],
    "users": [
      { "name": "admin", "uuid": "11111111-1111-4111-8111-111111111111", "privileged": true },
      { "name": "guest", "uuid": "22222222-2222-4222-8222-222222222222", "privileged": false }
    ],
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
  local src="$1" dest="$2"
  ansible localhost, -c local -m template \
    -a "src=${here}/templates/${src} dest=${dest}" \
    -e "@${fixture}" >/dev/null 2>&1 || { echo "render ${src} failed" >&2; exit 2; }
}

render nginx.conf.j2 "${tmp}/nginx.conf"
render default.conf.j2 "${tmp}/default.conf"
render fallback.conf.j2 "${tmp}/fallback.conf"
render xray-config.json.j2 "${tmp}/xray-config.json"

# --- xray config parses --------------------------------------------------------
jq . "${tmp}/xray-config.json" >/dev/null 2>&1 ||
  { echo "rendered xray config is not valid JSON" >&2; exit 2; }

# --- individual directives -----------------------------------------------------
if grep -Eq '^[[:space:]]*proxy_protocol[[:space:]]+on;' "${tmp}/nginx.conf"; then
  pass "nginx stream sends PROXY protocol to its upstreams"
else
  fail "nginx stream server block lacks 'proxy_protocol on;'"
fi

xray_accept="$(jq -r '.inbounds[] | select(.tag == "vless-reality")
                     | .streamSettings.sockopt.acceptProxyProtocol // false
                     | tostring' "${tmp}/xray-config.json")"
if [ "${xray_accept}" = "true" ]; then
  pass "xray inbound accepts PROXY protocol (sockopt.acceptProxyProtocol)"
else
  fail "xray vless-reality inbound lacks sockopt.acceptProxyProtocol: true"
fi

xray_xver="$(jq -r '.inbounds[] | select(.tag == "vless-reality")
                    | .streamSettings.realitySettings.xver // 0' "${tmp}/xray-config.json")"
if [ "${xray_xver}" = "1" ]; then
  pass "xray reality sends PROXY protocol v1 to dest (xver: 1)"
else
  fail "xray realitySettings.xver is '${xray_xver}', expected 1"
fi

site_pp() {
  local file="$1" port="$2" what="$3"
  local ok=1
  grep -Eq "listen[[:space:]]+127\\.0\\.0\\.1:${port}[^;]*proxy_protocol" "${tmp}/${file}" || ok=0
  grep -Eq "^[[:space:]]*set_real_ip_from[[:space:]]+127\.0\.0\.1;" "${tmp}/${file}" || ok=0
  grep -Eq '^[[:space:]]*real_ip_header[[:space:]]+proxy_protocol;' "${tmp}/${file}" || ok=0
  if [ "${ok}" -eq 1 ]; then
    pass "${what} listens proxy_protocol and restores the real client address"
  else
    fail "${what} must listen proxy_protocol with set_real_ip_from/real_ip_header"
  fi
}
site_pp default.conf 20000 "default site (20000)"
site_pp fallback.conf 8443 "fallback vhost (8443)"

# --- pairwise consistency: one-sided flips are outages -------------------------
stream_pp="$(grep -Ec '^[[:space:]]*proxy_protocol[[:space:]]+on;' "${tmp}/nginx.conf")"

if { [ "${stream_pp}" -gt 0 ] && [ "${xray_accept}" = "true" ]; } ||
   { [ "${stream_pp}" -eq 0 ] && [ "${xray_accept}" = "false" ]; }; then
  pass "pair: nginx stream PP ⟺ xray acceptProxyProtocol"
else
  fail "pair broken: nginx stream PP=${stream_pp}, xray accept=${xray_accept} — one side alone drops every VPN connection"
fi

default_pp="$(grep -Ec "listen[[:space:]]+127\\.0\\.0\\.1:20000[^;]*proxy_protocol" "${tmp}/default.conf")"
if [ "${stream_pp}" -gt 0 ] && [ "${default_pp}" -eq 0 ]; then
  fail "pair broken: stream sends PP but the default site does not listen proxy_protocol — wrong-SNI probes die"
elif [ "${stream_pp}" -eq 0 ] && [ "${default_pp}" -gt 0 ]; then
  fail "pair broken: default site listens proxy_protocol but nothing sends it"
else
  pass "pair: nginx stream PP ⟺ default site proxy_protocol"
fi

fallback_pp="$(grep -Ec "listen[[:space:]]+127\\.0\\.0\\.1:8443[^;]*proxy_protocol" "${tmp}/fallback.conf")"
if [ "${xray_xver}" -ge 1 ] && [ "${fallback_pp}" -eq 0 ]; then
  fail "pair broken: xver=${xray_xver} sends PP but fallback does not listen proxy_protocol — Reality dest mirroring dies (#10)"
elif [ "${xray_xver}" -eq 0 ] && [ "${fallback_pp}" -gt 0 ]; then
  fail "pair broken: fallback listens proxy_protocol but xray sends no PP (xver 0)"
else
  pass "pair: reality xver ⟺ fallback proxy_protocol"
fi

echo
if [ "${failures}" -gt 0 ]; then
  echo "RED: ${failures} check(s) failed"
  exit 1
fi
echo "GREEN: PROXY protocol chain is consistent end to end"
