#!/bin/bash
#
# 10-user-sshd.sh — the access contract (SPEC §4).
#
# Re-asserts what user-data.yaml did minimally, intentionally: user-data is a
# bootstrap shim (SPEC §7), this unit is the contract. Asserts user `ib`
# (groups sudo,adm, NOPASSWD sudo, locked password, zsh shell, authorized
# key) and writes the full sshd hardening config from
# cloud-init/cloud-init-ubuntu.yaml (port 42318, pubkey-only, AllowUsers ib,
# no root).
#
# Idempotency guards: user/file existence, content compares; ssh is only
# restarted when the hardening config changed.
#
set -euo pipefail

user_name="ib"
user_home="/home/${user_name}"
authorized_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOU3h/cYVAtFlzRyUG7e2KOrIbLUpuZnTf81ZRd/yIMC"
sudoers_file="/etc/sudoers.d/90-ib-nopasswd"
sshd_dropin="/etc/ssh/sshd_config.d/60-ib-hardening.conf"

# --- user ---------------------------------------------------------------

if ! id "${user_name}" >/dev/null 2>&1; then
  useradd -m -s /usr/bin/zsh -G sudo,adm "${user_name}"
  echo "10-user-sshd: created user ${user_name}"
fi

user_group="$(id -gn "${user_name}")"

usermod -aG sudo,adm "${user_name}"

if [ "$(getent passwd "${user_name}" | cut -d: -f7)" != "/usr/bin/zsh" ]; then
  chsh -s /usr/bin/zsh "${user_name}"
  echo "10-user-sshd: shell set to /usr/bin/zsh"
fi

# Locked password (pubkey-only); passwd -S reports 'L' when locked.
if ! passwd -S "${user_name}" | grep -qE '\bL\b'; then
  passwd -l "${user_name}" >/dev/null
  echo "10-user-sshd: password locked"
fi

# NOPASSWD sudo (as cloud-init writes it); validated before install.
desired_sudoers="$(mktemp)"
trap 'rm -f "${desired_sudoers}"' EXIT
echo "${user_name} ALL=(ALL) NOPASSWD:ALL" > "${desired_sudoers}"
visudo -cf "${desired_sudoers}" >/dev/null
if [ -f "${sudoers_file}" ] && cmp -s "${desired_sudoers}" "${sudoers_file}"; then
  echo "10-user-sshd: ${sudoers_file} already in place"
else
  install -m 0440 -o root -g root "${desired_sudoers}" "${sudoers_file}"
  echo "10-user-sshd: wrote ${sudoers_file}"
fi

# Authorized key.
install -d -m 0700 -o "${user_name}" -g "${user_group}" "${user_home}/.ssh"
if [ -f "${user_home}/.ssh/authorized_keys" ] \
  && grep -qxF "${authorized_key}" "${user_home}/.ssh/authorized_keys"; then
  echo "10-user-sshd: authorized key already present"
else
  echo "${authorized_key}" >> "${user_home}/.ssh/authorized_keys"
  chown "${user_name}:${user_group}" "${user_home}/.ssh/authorized_keys"
  chmod 0600 "${user_home}/.ssh/authorized_keys"
  echo "10-user-sshd: authorized key installed"
fi

# Home directory scaffolding shared by the later units.
install -d -m 0755 -o "${user_name}" -g "${user_group}" "${user_home}/.config"
install -d -m 0755 -o "${user_name}" -g "${user_group}" "${user_home}/.local/share"
install -d -m 0755 -o "${user_name}" -g "${user_group}" "${user_home}/.cache"
install -d -m 0700 -o "${user_name}" -g "${user_group}" "${user_home}/.local/state"

# --- sshd hardening -----------------------------------------------------

desired_sshd="$(mktemp)"
trap 'rm -f "${desired_sudoers}" "${desired_sshd}"' EXIT
cat > "${desired_sshd}" <<'EOF'
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

if [ -f "${sshd_dropin}" ] && cmp -s "${desired_sshd}" "${sshd_dropin}"; then
  echo "10-user-sshd: ${sshd_dropin} already in place"
else
  install -m 0644 -o root -g root "${desired_sshd}" "${sshd_dropin}"
  sshd -t
  systemctl restart ssh
  echo "10-user-sshd: wrote ${sshd_dropin} and restarted ssh"
fi
