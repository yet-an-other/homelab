#!/bin/bash
#
# 40-xray.sh — xray-core install + service (SPEC §5, issue #10).
#
# Runs the vendored lib/install-xray.sh (idempotent install/upgrade of
# xray-core via the official XTLS installer), validates the config rendered
# by the play (/usr/local/etc/xray/config.json), and enables/starts the
# service — restarting only when the config changed since the last applied
# stamp. xray logs to stdout/stderr, which the foreground xray.service pipes
# into the dedicated `xform` journal namespace (drop-in placed here) so the
# panel's unprivileged user can read exactly this unit's log (SPEC §6); the
# logrotate config earlier revisions wrote is removed here.
#
# Idempotency guards: the installer is idempotent; the stale logrotate config
# is removed only if present; the drop-in is content-compared; restart is
# gated on the config mtime vs the stamp or a drop-in change.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

unit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="/usr/local/etc/xray/config.json"
state_dir="/var/lib/forpost"
stamp="${state_dir}/xray-config.stamp"
logrotate_conf="/etc/logrotate.d/xray"
dropin="/etc/systemd/system/xray.service.d/10-xform-journal.conf"
dropin_changed=0

# Pinned: the rendered config's field names (e.g. reality `password`) are
# matched to this version — bump deliberately (SPEC §6, research Q4).
xray_version="v26.3.27"

# --- install / upgrade ----------------------------------------------------

bash "${unit_dir}/lib/install-xray.sh" --version "${xray_version}"

# --- logrotate cleanup ------------------------------------------------------
# xray now logs to the journal; drop the logrotate config earlier revisions
# wrote for /var/log/xray/*.log. The official installer only seeds its own
# copy when passed --logrotate, which the wrapper never does.

if [ -f "${logrotate_conf}" ]; then
  rm -f "${logrotate_conf}"
  echo "40-xray: removed stale ${logrotate_conf}"
fi

# --- journal namespace drop-in -----------------------------------------------
# Assign xray's records to the `xform` journal namespace so the panel can read
# them (SPEC §6). The xform user's read access is ACL-bounded to the namespace
# by units/lib/xform-journal-acl.conf (43-xform.sh). `journalctl -u xray`
# shows only pre-migration records; the live log is
# `journalctl --namespace=xform -u xray.service`.

desired_dropin="$(mktemp)"
trap 'rm -f "${desired_dropin}"' EXIT
cat > "${desired_dropin}" <<'EOF'
[Service]
LogNamespace=xform
EOF

if [ -f "${dropin}" ] && cmp -s "${desired_dropin}" "${dropin}"; then
  echo "40-xray: ${dropin} already in place"
else
  install -d -m 0755 "$(dirname "${dropin}")"
  install -m 0644 -o root -g root "${desired_dropin}" "${dropin}"
  systemctl daemon-reload
  dropin_changed=1
  echo "40-xray: wrote ${dropin}"
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
elif [ "${dropin_changed}" -eq 1 ] || [ ! -f "${stamp}" ] || [ "${config}" -nt "${stamp}" ]; then
  systemctl restart xray
  touch -r "${config}" "${stamp}"
  echo "40-xray: config or drop-in changed, xray restarted"
else
  echo "40-xray: config unchanged, xray left running"
fi
