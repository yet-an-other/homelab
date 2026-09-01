#!/bin/bash
#
# journal-namespace.sh — the journal namespace contract across forpost's
# templates and units (SPEC §6/§8; upstream xform docs/journal-namespace.md).
#
# The panel's Log snapshot readers exec journalctl as the unprivileged xform
# user, bounded by a dedicated journal namespace instead of systemd-journal
# group membership. That takes three artifacts staying in lockstep:
#
#   xform.service.j2   LogNamespace=<ns> + XFORM_JOURNALCTL + ExecStartPre
#                      that re-applies the ACL tmpfiles file on every start
#   40-xray.sh         drop-in assigning the same <ns> to the xray unit
#   43-xform.sh        installs units/lib/xform-journal-acl.conf to the path
#                      the ExecStartPre references
#
# A drift in any one — namespace name, tmpfiles path, a missing drop-in —
# silently degrades the panel to access_denied/journalctl_unavailable or
# strands xray's logs where the panel cannot read them.
#
# Exit 0 = consistent, exit 1 = RED (printed), exit 2 = harness failure.
# (No `set -e`: failures are accumulated and reported together.)
#
# Usage: tests/journal-namespace.sh
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

# Fixture: the one var xform.service.j2 templates.
cat >"${tmp}/fixture.json" <<'EOF'
{ "forpost": { "xform_password": "fixture-panel-password" } }
EOF

ansible localhost, -c local -m template \
  -a "src=${here}/templates/xform.service.j2 dest=${tmp}/xform.service" \
  -e "@${tmp}/fixture.json" >/dev/null 2>&1 ||
  { echo "render xform.service.j2 failed" >&2; exit 2; }

unit="${tmp}/xform.service"
acl_file="${here}/units/lib/xform-journal-acl.conf"

# --- the panel unit carries the namespace + journalctl env --------------------

ns="$(sed -n 's/^LogNamespace=//p' "${unit}" | head -1)"
if [ -n "${ns}" ]; then
  pass "panel unit assigns a journal namespace (${ns})"
else
  fail "xform.service.j2 must set LogNamespace=<ns> — without it the panel's own logs stay in the default journal"
fi

if grep -q '^Environment=XFORM_JOURNALCTL=/usr/bin/journalctl$' "${unit}"; then
  pass "unit pins XFORM_JOURNALCTL=/usr/bin/journalctl"
else
  fail "xform.service.j2 must set XFORM_JOURNALCTL=/usr/bin/journalctl — the panel refuses to start on a non-absolute/non-executable path"
fi

tmpfiles_path="$(sed -n 's/^ExecStartPre=-+\/usr\/bin\/systemd-tmpfiles --create //p' "${unit}" | head -1)"
if [ -n "${tmpfiles_path}" ]; then
  pass "unit re-applies the ACL tmpfiles file on every start (${tmpfiles_path})"
else
  fail "xform.service.j2 must carry ExecStartPre=-+/usr/bin/systemd-tmpfiles --create <acl file> — volatile hosts need it after every boot"
fi

# --- xray joins the same namespace via 40-xray.sh's drop-in -------------------

if [ -n "${ns}" ] && grep -q "^LogNamespace=${ns}$" "${here}/units/40-xray.sh"; then
  pass "pair: 40-xray.sh drop-in assigns xray the same namespace (${ns})"
else
  fail "units/40-xray.sh must drop LogNamespace=${ns} onto the xray unit — the panel reads only the namespace, never the default journal"
fi

if grep -q 'systemd/system/xray.service.d/' "${here}/units/40-xray.sh"; then
  pass "pair: drop-in targets the canonical xray.service.d directory"
else
  fail "40-xray.sh must place the drop-in under /etc/systemd/system/xray.service.d/"
fi

# --- the ACL file exists, covers both journal roots, and names the namespace --

if [ -f "${acl_file}" ]; then
  pass "units/lib/xform-journal-acl.conf ships in the pushed bundle"
else
  fail "units/lib/xform-journal-acl.conf is missing — 43-xform.sh installs it from the bundle"
fi

if [ -n "${ns}" ] && [ -f "${acl_file}" ]; then
  for root in /var/log/journal /run/log/journal; do
    if grep -q "^a+[[:space:]]\+${root}/%m\.${ns}[[:space:]]" "${acl_file}" &&
      grep -q "^A+[[:space:]]\+${root}/%m\.${ns}/\*[[:space:]]" "${acl_file}"; then
      pass "ACL rules cover ${root}/%m.${ns} (directory + children)"
    else
      fail "ACL rules must cover ${root}/%m.${ns} and its children — a host may journal persistently, volatilely, or both"
    fi
  done
fi

# --- pair: the ExecStartPre path is the path 43-xform.sh installs --------------

if [ -n "${tmpfiles_path}" ] && grep -q "tmpfiles_conf=\"${tmpfiles_path}\"" "${here}/units/43-xform.sh"; then
  pass "pair: ExecStartPre tmpfiles path ⟺ 43-xform.sh install path"
else
  fail "43-xform.sh must install the ACL file at exactly the path the unit's ExecStartPre references (${tmpfiles_path:-none found})"
fi

echo
if [ "${failures}" -gt 0 ]; then
  echo "RED: ${failures} check(s) failed"
  exit 1
fi
echo "GREEN: journal namespace contract holds end to end"
