#!/bin/bash
#
# 40-xray.sh — xray-core install + service (SPEC §5, issue #10).
#
# Runs the vendored lib/install-xray.sh (idempotent install/upgrade of
# xray-core via the official XTLS installer), places logrotate for
# /var/log/xray/*.log, validates the config rendered by the play
# (/usr/local/etc/xray/config.json), and enables/starts the service —
# restarting only when the config changed since the last applied stamp.
#
# Idempotency guards: the installer is idempotent; logrotate config is
# content-compared; restart is gated on the config mtime vs the stamp.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

unit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="/usr/local/etc/xray/config.json"
state_dir="/var/lib/forpost"
stamp="${state_dir}/xray-config.stamp"
logrotate_conf="/etc/logrotate.d/xray"

# Pinned: the rendered config's field names (e.g. reality `password`) are
# matched to this version — bump deliberately (SPEC §6, research Q4).
xray_version="v26.3.27"

# --- install / upgrade ----------------------------------------------------

bash "${unit_dir}/lib/install-xray.sh" --version "${xray_version}"

# The config logs to /var/log/xray (SPEC §6); make sure `xray -test` and the
# service can open the files even on a fresh node.
install -d -m 0755 /var/log/xray

# --- logrotate --------------------------------------------------------------
# The official installer seeds its own /etc/logrotate.d/xray (rotate 7, no
# copytruncate — xray holds its log fds, so a rename-rotate would strand the
# stream in the old file). We deliberately override it with copytruncate.

if ! dpkg -s logrotate >/dev/null 2>&1; then
  apt-get update
  apt-get install -y logrotate
fi

desired_logrotate="$(mktemp)"
trap 'rm -f "${desired_logrotate}"' EXIT
cat > "${desired_logrotate}" <<'EOF'
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

if [ -f "${logrotate_conf}" ] && cmp -s "${desired_logrotate}" "${logrotate_conf}"; then
  echo "40-xray: ${logrotate_conf} already in place"
else
  install -m 0644 -o root -g root "${desired_logrotate}" "${logrotate_conf}"
  echo "40-xray: wrote ${logrotate_conf}"
fi

# --- config + service -------------------------------------------------------

if [ ! -f "${config}" ]; then
  echo "40-xray: ${config} is missing — the play renders it before units run" >&2
  exit 1
fi

/usr/local/bin/xray -test -config "${config}"

mkdir -p "${state_dir}"
systemctl enable xray

if ! systemctl is-active --quiet xray; then
  systemctl start xray
  touch -r "${config}" "${stamp}"
  echo "40-xray: xray started"
elif [ ! -f "${stamp}" ] || [ "${config}" -nt "${stamp}" ]; then
  systemctl restart xray
  touch -r "${config}" "${stamp}"
  echo "40-xray: config changed, xray restarted"
else
  echo "40-xray: config unchanged, xray left running"
fi
