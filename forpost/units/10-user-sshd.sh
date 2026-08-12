#!/bin/bash
#
# 10-user-sshd.sh — assert user `ib` and sshd hardening.
#
# Re-asserts what user-data.yaml did minimally on first boot — intentional:
# user-data is a bootstrap shim, this unit is the contract.
#
# Guards: user existence; file content compares; sshd/socket restart only on change.
#
set -euo pipefail

USER_NAME="ib"
USER_HOME="/home/${USER_NAME}"
AUTH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOU3h/cYVAtFlzRyUG7e2KOrIbLUpuZnTf81ZRd/yIMC"

CHANGED=0

# ---- user -------------------------------------------------------------------
if ! id "${USER_NAME}" >/dev/null 2>&1; then
  useradd -m -s /usr/bin/zsh -G sudo,adm "${USER_NAME}"
fi
usermod -aG sudo,adm -s /usr/bin/zsh "${USER_NAME}"
passwd -l "${USER_NAME}" >/dev/null

USER_GROUP="$(id -gn "${USER_NAME}")"

# ---- NOPASSWD sudo -----------------------------------------------------------
SUDOERS="/etc/sudoers.d/90-${USER_NAME}"
SUDOERS_CONTENT="${USER_NAME} ALL=(ALL) NOPASSWD:ALL"
if [ ! -f "${SUDOERS}" ] || [ "$(cat "${SUDOERS}")" != "${SUDOERS_CONTENT}" ]; then
  printf '%s\n' "${SUDOERS_CONTENT}" > "${SUDOERS}"
  chmod 0440 "${SUDOERS}"
fi

# ---- authorized key ----------------------------------------------------------
install -d -m 0700 -o "${USER_NAME}" -g "${USER_GROUP}" "${USER_HOME}/.ssh"
AUTHORIZED_KEYS="${USER_HOME}/.ssh/authorized_keys"
touch "${AUTHORIZED_KEYS}"
if ! grep -qxF "${AUTH_KEY}" "${AUTHORIZED_KEYS}"; then
  printf '%s\n' "${AUTH_KEY}" >> "${AUTHORIZED_KEYS}"
fi
chown "${USER_NAME}:${USER_GROUP}" "${AUTHORIZED_KEYS}"
chmod 0600 "${AUTHORIZED_KEYS}"

# ---- sshd hardening ----------------------------------------------------------
SSHD_CONF="/etc/ssh/sshd_config.d/60-ib-hardening.conf"
read -r -d '' HARDENING <<'EOF' || true
Port 42318
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
AllowUsers ib
EOF

install -d -m 0755 /etc/ssh/sshd_config.d
if [ ! -f "${SSHD_CONF}" ] || [ "$(cat "${SSHD_CONF}")" != "${HARDENING}" ]; then
  printf '%s\n' "${HARDENING}" > "${SSHD_CONF}"
  chmod 0644 "${SSHD_CONF}"
  CHANGED=1
fi

# Socket-activated ssh (Ubuntu 24.04+): the socket, not sshd_config, owns the
# listen port there — pin it to 42318 as well.
SOCKET_DIR="/etc/systemd/system/ssh.socket.d"
SOCKET_CONF="${SOCKET_DIR}/listen-42318.conf"
if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
  read -r -d '' SOCKET <<'EOF' || true
[Socket]
ListenStream=
ListenStream=42318
EOF
  if [ ! -f "${SOCKET_CONF}" ] || [ "$(cat "${SOCKET_CONF}")" != "${SOCKET}" ]; then
    install -d -m 0755 "${SOCKET_DIR}"
    printf '%s\n' "${SOCKET}" > "${SOCKET_CONF}"
    CHANGED=1
  fi
fi

sshd -t

if [ "${CHANGED}" -eq 1 ]; then
  systemctl daemon-reload
  systemctl restart ssh
  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    systemctl restart ssh.socket
  fi
  echo "sshd config changed; ssh restarted"
else
  echo "sshd config already up to date"
fi
