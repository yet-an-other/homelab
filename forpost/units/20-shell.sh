#!/bin/bash
#
# 20-shell.sh — oh-my-zsh, powerlevel10k, zsh-syntax-highlighting, dotfiles.
# Mirrors the shell part of cloud-init/cloud-init-ubuntu.yaml.
# Guard: `[ ! -d .../.git ]` per clone (existing repo pattern).
#
set -euo pipefail

USER_NAME="ib"
USER_HOME="/home/${USER_NAME}"
USER_GROUP="$(id -gn "${USER_NAME}")"
DOTFILES_DIR="${USER_HOME}/.dotfiles"
ZSHRC_SOURCE="${DOTFILES_DIR}/zsh-ssh/.zshrc"
P10K_SOURCE="${DOTFILES_DIR}/zsh-ssh/.p10k.zsh"

run_as_user() {
  sudo -u "${USER_NAME}" -H bash -lc "$1"
}

if [ ! -d "${USER_HOME}/.oh-my-zsh/.git" ]; then
  run_as_user "git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git '${USER_HOME}/.oh-my-zsh'"
fi

install -d -m 0755 -o "${USER_NAME}" -g "${USER_GROUP}" "${USER_HOME}/.oh-my-zsh/custom/themes"
install -d -m 0755 -o "${USER_NAME}" -g "${USER_GROUP}" "${USER_HOME}/.oh-my-zsh/custom/plugins"

if [ ! -d "${USER_HOME}/.oh-my-zsh/custom/themes/powerlevel10k/.git" ]; then
  run_as_user "git clone --depth 1 https://github.com/romkatv/powerlevel10k.git '${USER_HOME}/.oh-my-zsh/custom/themes/powerlevel10k'"
fi

if [ ! -d "${USER_HOME}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/.git" ]; then
  run_as_user "git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting.git '${USER_HOME}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting'"
fi

if [ ! -d "${DOTFILES_DIR}/.git" ]; then
  run_as_user "git clone --branch main --depth 1 https://github.com/yet-an-other/dotfiles.git '${DOTFILES_DIR}'"
fi

if [ ! -f "${ZSHRC_SOURCE}" ]; then
  echo "missing dotfiles source: ${ZSHRC_SOURCE}" >&2
  exit 1
fi

if [ ! -f "${P10K_SOURCE}" ]; then
  echo "missing dotfiles source: ${P10K_SOURCE}" >&2
  exit 1
fi

run_as_user "ln -sfn '${ZSHRC_SOURCE}' '${USER_HOME}/.zshrc'"
run_as_user "ln -sfn '${P10K_SOURCE}' '${USER_HOME}/.p10k.zsh'"
chown -h "${USER_NAME}:${USER_GROUP}" "${USER_HOME}/.zshrc" "${USER_HOME}/.p10k.zsh"
