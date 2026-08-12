#!/bin/bash
#
# 21-fonts.sh — JetBrainsMono Nerd Font for user `ib`.
# Guard: skip the download when the fonts directory already has .ttf files
# (reinstall-safe: rm -f the archive, unzip -oq overwrites cleanly).
#
set -euo pipefail

USER_NAME="ib"
USER_HOME="/home/${USER_NAME}"
USER_GROUP="$(id -gn "${USER_NAME}")"
FONTS_DIR="${USER_HOME}/.local/share/fonts/JetBrainsMonoNerdFont"
FONTS_ARCHIVE="/tmp/JetBrainsMono.zip"

run_as_user() {
  sudo -u "${USER_NAME}" -H bash -lc "$1"
}

install -d -m 0755 -o "${USER_NAME}" -g "${USER_GROUP}" "${FONTS_DIR}"

if ls "${FONTS_DIR}"/*.ttf >/dev/null 2>&1; then
  echo "JetBrainsMono Nerd Font already installed"
  exit 0
fi

run_as_user "curl -fsSL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip -o '${FONTS_ARCHIVE}'"
run_as_user "unzip -oq '${FONTS_ARCHIVE}' -d '${FONTS_DIR}'"
run_as_user "rm -f '${FONTS_ARCHIVE}'"
run_as_user "fc-cache -f '${USER_HOME}/.local/share/fonts'"
