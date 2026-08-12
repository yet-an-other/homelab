#!/bin/bash
#
# 30-editor.sh — neovim (latest release tarball, arch-aware) + LazyVim starter
# + keymaps.lua symlink from the dotfiles repo.
# Guards: version marker file under /opt; LazyVim only cloned when no
# lazyvim.json exists (existing config is backed up first, cloud-init pattern).
#
set -euo pipefail

USER_NAME="ib"
USER_HOME="/home/${USER_NAME}"
USER_GROUP="$(id -gn "${USER_NAME}")"
DOTFILES_DIR="${USER_HOME}/.dotfiles"
NVIM_CONFIG_DIR="${USER_HOME}/.config/nvim"
NVIM_CACHE_DIR="${USER_HOME}/.cache/nvim"
NVIM_DATA_DIR="${USER_HOME}/.local/share/nvim"
NVIM_STATE_DIR="${USER_HOME}/.local/state/nvim"

run_as_user() {
  sudo -u "${USER_NAME}" -H bash -lc "$1"
}

# ---- arch detection ----------------------------------------------------------
ARCH="$(dpkg --print-architecture)"
case "${ARCH}" in
  amd64) NVIM_ARCH="x86_64" ;;
  arm64) NVIM_ARCH="arm64" ;;
  *)
    echo "unsupported architecture for neovim install: ${ARCH}" >&2
    exit 1
    ;;
esac

NVIM_INSTALL_DIR="/opt/nvim-linux-${NVIM_ARCH}"
NVIM_ARCHIVE="/tmp/nvim-linux-${NVIM_ARCH}.tar.gz"
VERSION_MARKER="${NVIM_INSTALL_DIR}/.forpost-version"

# ---- neovim binary ------------------------------------------------------------
LATEST_TAG="$(curl -fsSL https://api.github.com/repos/neovim/neovim/releases/latest | jq -r .tag_name)"
if [ -z "${LATEST_TAG}" ] || [ "${LATEST_TAG}" = "null" ]; then
  echo "unable to resolve latest neovim release" >&2
  exit 1
fi

if [ ! -x /usr/local/bin/nvim ] || [ ! -f "${VERSION_MARKER}" ] || [ "$(cat "${VERSION_MARKER}")" != "${LATEST_TAG}" ]; then
  curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${NVIM_ARCH}.tar.gz" -o "${NVIM_ARCHIVE}"
  rm -rf "${NVIM_INSTALL_DIR}"
  tar -C /opt -xzf "${NVIM_ARCHIVE}"
  rm -f "${NVIM_ARCHIVE}"
  ln -sfn "${NVIM_INSTALL_DIR}/bin/nvim" /usr/local/bin/nvim
  printf '%s' "${LATEST_TAG}" > "${VERSION_MARKER}"
  echo "installed neovim ${LATEST_TAG} (${NVIM_ARCH})"
else
  echo "neovim ${LATEST_TAG} already installed"
fi

# ---- LazyVim starter -----------------------------------------------------------
install -d -m 0755 -o "${USER_NAME}" -g "${USER_GROUP}" "${USER_HOME}/.config"
install -d -m 0755 -o "${USER_NAME}" -g "${USER_GROUP}" "${NVIM_CACHE_DIR}"
install -d -m 0755 -o "${USER_NAME}" -g "${USER_GROUP}" "${NVIM_DATA_DIR}"
install -d -m 0700 -o "${USER_NAME}" -g "${USER_GROUP}" "${NVIM_STATE_DIR}"

if [ -d "${NVIM_CONFIG_DIR}" ] && [ ! -f "${NVIM_CONFIG_DIR}/lazyvim.json" ]; then
  mv "${NVIM_CONFIG_DIR}" "${NVIM_CONFIG_DIR}.bak.$(date +%s)"
fi

if [ ! -f "${NVIM_CONFIG_DIR}/lazyvim.json" ]; then
  run_as_user "git clone --depth 1 https://github.com/LazyVim/starter '${NVIM_CONFIG_DIR}'"
  rm -rf "${NVIM_CONFIG_DIR}/.git"
fi

install -d -m 0755 -o "${USER_NAME}" -g "${USER_GROUP}" "${NVIM_CONFIG_DIR}/lua/config"

# ---- keymaps.lua from dotfiles --------------------------------------------------
KEYMAPS_SOURCE=""
for candidate in \
  "${DOTFILES_DIR}/nvim/keymaps.lua" \
  "${DOTFILES_DIR}/nvim/lua/config/keymaps.lua"
do
  if [ -f "${candidate}" ]; then
    KEYMAPS_SOURCE="${candidate}"
    break
  fi
done

if [ -z "${KEYMAPS_SOURCE}" ]; then
  echo "missing keymaps.lua in ${DOTFILES_DIR}/nvim (run 20-shell.sh first)" >&2
  exit 1
fi

run_as_user "ln -sfn '${KEYMAPS_SOURCE}' '${NVIM_CONFIG_DIR}/lua/config/keymaps.lua'"
chown -h "${USER_NAME}:${USER_GROUP}" "${NVIM_CONFIG_DIR}/lua/config/keymaps.lua"
