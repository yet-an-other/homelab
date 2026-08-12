#!/bin/bash
#
# 01-unattended-upgrades.sh — enable automatic security updates.
# Guard: only write the config when its content differs.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

CONF="/etc/apt/apt.conf.d/20auto-upgrades"

read -r -d '' CONTENT <<'EOF' || true
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

if [ ! -f "${CONF}" ] || [ "$(cat "${CONF}")" != "${CONTENT}" ]; then
  printf '%s\n' "${CONTENT}" > "${CONF}"
  chmod 0644 "${CONF}"
  echo "wrote ${CONF}"
else
  echo "${CONF} already up to date"
fi
