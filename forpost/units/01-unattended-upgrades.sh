#!/bin/bash
#
# 01-unattended-upgrades.sh — automatic security updates (SPEC §4).
#
# Idempotency guard: the 20auto-upgrades config is only (re)written when its
# content differs.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

auto_upgrades="/etc/apt/apt.conf.d/20auto-upgrades"

if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
  apt-get update
  apt-get install -y unattended-upgrades
fi

desired="$(mktemp)"
trap 'rm -f "${desired}"' EXIT
cat > "${desired}" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

if [ -f "${auto_upgrades}" ] && cmp -s "${desired}" "${auto_upgrades}"; then
  echo "01-unattended-upgrades: ${auto_upgrades} already in place"
else
  install -m 0644 -o root -g root "${desired}" "${auto_upgrades}"
  echo "01-unattended-upgrades: wrote ${auto_upgrades}"
fi
