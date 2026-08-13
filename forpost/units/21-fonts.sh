#!/bin/bash
#
# 21-fonts.sh — JetBrainsMono Nerd Font (SPEC §4).
#
# Installs the latest JetBrainsMono Nerd Font release into
# ~/.local/share/fonts and refreshes the font cache. Replica of the fonts
# section of cloud-init/cloud-init-ubuntu.yaml.
#
# Idempotency guard: skipped when the font family is already present;
# `unzip -oq` makes a re-run reinstall-safe regardless.
#
set -euo pipefail

user_name="ib"
user_home="/home/${user_name}"
fonts_dir="${user_home}/.local/share/fonts/JetBrainsMonoNerdFont"
fonts_archive="/tmp/JetBrainsMono.zip"

run_as_user() {
  sudo -u "${user_name}" -H bash -lc "$1"
}

install -d -m 0755 -o "${user_name}" -g "$(id -gn "${user_name}")" "${fonts_dir}"

if find "${fonts_dir}" -name 'JetBrainsMonoNerdFont*.ttf' -print -quit | grep -q .; then
  echo "21-fonts: JetBrainsMono Nerd Font already installed"
  exit 0
fi

run_as_user "curl -fsSL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip -o '${fonts_archive}'"
run_as_user "unzip -oq '${fonts_archive}' -d '${fonts_dir}'"
run_as_user "rm -f '${fonts_archive}'"
run_as_user "fc-cache -f '${user_home}/.local/share/fonts'"

echo "21-fonts: JetBrainsMono Nerd Font installed"
