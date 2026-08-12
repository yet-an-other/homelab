#!/bin/bash
#
# 40-xray.sh — install xray-core, logrotate for /var/log/xray, enable and
# (re)start the service when the rendered config changes.
#
# The config itself is rendered by the play into /usr/local/etc/xray/config.json
# before this unit runs; this unit never templates — it verifies and restarts.
#
# Env knobs:
#   FORPOST_XRAY_UPGRADE=1   run the installer even when xray is present
#   FORPOST_XRAY_VERSION=vX  pin the install/upgrade to a specific release
#
# The pinned default below matters: the rendered config uses the renamed
# outbound reality `password` field (formerly `publicKey`), which requires
# xray >= the rename (SPEC §6, docs/research/xray-vlessroute.md Q4).
#
set -euo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="/usr/local/etc/xray/config.json"
MARKER="/usr/local/etc/xray/.config.sha256"
LOGROTATE_CONF="/etc/logrotate.d/xray"
XRAY_VERSION="${FORPOST_XRAY_VERSION:-v26.3.27}"

# ---- install / upgrade ---------------------------------------------------------
# Installs the pinned version on first boot; re-runs are a no-op unless an
# upgrade is explicitly requested.
if ! command -v xray >/dev/null 2>&1 || [ "${FORPOST_XRAY_UPGRADE:-0}" = "1" ]; then
  "${UNIT_DIR}/lib/install-xray.sh" --version "${XRAY_VERSION}"
else
  echo "xray already installed (FORPOST_XRAY_UPGRADE=1 to upgrade to ${XRAY_VERSION})"
fi

# ---- logrotate ------------------------------------------------------------------
read -r -d '' LOGROTATE <<'EOF' || true
/var/log/xray/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

if [ ! -f "${LOGROTATE_CONF}" ] || [ "$(cat "${LOGROTATE_CONF}")" != "${LOGROTATE}" ]; then
  printf '%s\n' "${LOGROTATE}" > "${LOGROTATE_CONF}"
  chmod 0644 "${LOGROTATE_CONF}"
  echo "wrote ${LOGROTATE_CONF}"
fi

# ---- enable + restart on config change -------------------------------------------
if [ ! -f "${CONFIG}" ]; then
  echo "missing xray config: ${CONFIG} (the play renders it before this unit runs)" >&2
  exit 1
fi

/usr/local/bin/xray run -test -c "${CONFIG}"

SUM="$(sha256sum "${CONFIG}" | awk '{print $1}')"
systemctl enable xray
if [ ! -f "${MARKER}" ] || [ "$(cat "${MARKER}")" != "${SUM}" ] || ! systemctl is-active --quiet xray; then
  systemctl restart xray
  printf '%s' "${SUM}" > "${MARKER}"
  echo "xray restarted (config changed or service was down)"
else
  echo "xray config unchanged; service already active"
fi

systemctl is-active --quiet xray
