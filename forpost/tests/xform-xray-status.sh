#!/bin/bash
#
# xform-xray-status.sh — feedback loop for "panel cannot connect to xray".
#
# Logs into the panel exactly as a browser does (password from the running
# unit's environment, never printed) and asserts the panel's own xray status
# contract: GET /api/v1/xray must report status=running while xray is active.
#
# Exit 0 = green (status reported running), exit 1 = red (unreachable/stopped),
# exit 2 = probe itself failed (panel down, auth broke, ssh broke).
#
# Usage: tests/xform-xray-status.sh [hostname] [port] [identity-file]
#
# Auth goes through the ssh agent/config by default (forpost's authorized key
# lives in the agent, not in a file). Set XFORM_XRAY_STATUS_HOST to override
# the default host.
set -uo pipefail

host="${1:-ar-speed.bdgn.me}"
port="${2:-42318}"
key="${3:-}"

ssh_opts=(-p "$port" -o BatchMode=yes -o ConnectTimeout=10)
[ -n "$key" ] && ssh_opts+=(-i "$key")

status_json="$(ssh "${ssh_opts[@]}" "ib@${host}" '
  set -e
  PW="$(systemctl show xform.service -p Environment --value | tr " " "\n" | sed -n "s/^XFORM_PASSWORD=//p")"
  [ -n "$PW" ] || { echo "PROBE_NO_PASSWORD"; exit 0; }
  TOKEN="$(curl -si -H "Content-Type: application/json" -d "{\"password\":\"$PW\"}" \
    http://127.0.0.1:9090/api/v1/login \
    | tr -d "\r" | sed -n "s/.*[Ss]et-[Cc]ookie: xform_session=\([^;]*\).*/\1/p" | head -1)"
  [ -n "$TOKEN" ] || { echo "PROBE_NO_SESSION"; exit 0; }
  curl -s -H "Cookie: xform_session=$TOKEN" http://127.0.0.1:9090/api/v1/xray
' 2>/dev/null)" || { echo "PROBE_SSH_FAILED"; exit 2; }

case "$status_json" in
  *PROBE*) echo "$status_json (panel auth path broken — probe infra failure)"; exit 2 ;;
  "") echo "empty response (panel down?)"; exit 2 ;;
esac

echo "$status_json"
status="$(printf '%s' "$status_json" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')"
case "$status" in
  running) echo "GREEN: panel sees xray running"; exit 0 ;;
  unreachable) echo "RED: panel cannot reach xray (systemd query failing)"; exit 1 ;;
  stopped) echo "RED: panel reports xray stopped (xray itself down?)"; exit 1 ;;
  *) echo "unexpected status field: '$status'"; exit 2 ;;
esac
