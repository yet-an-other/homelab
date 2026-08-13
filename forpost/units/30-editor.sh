#!/bin/bash
#
# 30-editor.sh — neovim + LazyVim (SPEC §4).
#
# Installs the latest neovim tarball into /opt/nvim-linux-<arch> (arch-aware
# via dpkg --print-architecture), symlinks /usr/local/bin/nvim, seeds the
# LazyVim starter config, and symlinks keymaps.lua from the dotfiles repo.
# Replica of the editor section of cloud-init/cloud-init-ubuntu.yaml.
#
# Idempotency guards: the download is skipped when the installed nvim
# already matches the latest release tag; the starter clone is skipped when
# lazyvim.json exists; symlinks are `ln -sfn`.
#
set -euo pipefail

user_name="ib"
user_home="/home/${user_name}"
dotfiles_dir="${user_home}/.dotfiles"
nvim_config_dir="${user_home}/.config/nvim"
nvim_cache_dir="${user_home}/.cache/nvim"
nvim_data_dir="${user_home}/.local/share/nvim"
nvim_state_dir="${user_home}/.local/state/nvim"

run_as_user() {
  sudo -u "${user_name}" -H bash -lc "$1"
}

# --- arch detection -------------------------------------------------------

case "$(dpkg --print-architecture)" in
  amd64) nvim_arch="x86_64" ;;
  arm64) nvim_arch="arm64" ;;
  *)
    echo "30-editor: unsupported architecture: $(dpkg --print-architecture)" >&2
    exit 1
    ;;
esac

nvim_archive="/tmp/nvim-linux-${nvim_arch}.tar.gz"
nvim_install_dir="/opt/nvim-linux-${nvim_arch}"

# --- neovim binary ----------------------------------------------------------

latest_tag="$(curl -fsSL https://api.github.com/repos/neovim/neovim/releases/latest | jq -r '.tag_name')"
if [ -z "${latest_tag}" ] || [ "${latest_tag}" = "null" ]; then
  echo "30-editor: unable to resolve latest neovim release" >&2
  exit 1
fi

installed_tag=""
if [ -x /usr/local/bin/nvim ]; then
  # `nvim --version` starts with "NVIM v0.11.x"
  installed_tag="$(/usr/local/bin/nvim --version | head -n 1 | awk '{print $2}')"
fi

if [ "${installed_tag}" = "${latest_tag}" ] && [ -d "${nvim_install_dir}" ]; then
  echo "30-editor: neovim ${latest_tag} already installed"
else
  curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${nvim_arch}.tar.gz" -o "${nvim_archive}"
  rm -rf "${nvim_install_dir}"
  tar -C /opt -xzf "${nvim_archive}"
  rm -f "${nvim_archive}"
  ln -sfn "${nvim_install_dir}/bin/nvim" /usr/local/bin/nvim
  echo "30-editor: neovim ${latest_tag} installed"
fi

# --- user dirs ------------------------------------------------------------

install -d -m 0755 -o "${user_name}" -g "$(id -gn "${user_name}")" "${nvim_cache_dir}"
install -d -m 0755 -o "${user_name}" -g "$(id -gn "${user_name}")" "${nvim_data_dir}"
install -d -m 0700 -o "${user_name}" -g "$(id -gn "${user_name}")" "${nvim_state_dir}"

# --- LazyVim starter --------------------------------------------------------

if [ -d "${nvim_config_dir}" ] && [ ! -f "${nvim_config_dir}/lazyvim.json" ]; then
  mv "${nvim_config_dir}" "${nvim_config_dir}.bak.$(date +%s)"
fi

if [ ! -f "${nvim_config_dir}/lazyvim.json" ]; then
  run_as_user "git clone --depth 1 https://github.com/LazyVim/starter '${nvim_config_dir}'"
  rm -rf "${nvim_config_dir}/.git"
fi

install -d -m 0755 -o "${user_name}" -g "$(id -gn "${user_name}")" "${nvim_config_dir}/lua/config"

keymaps_source=""
for candidate in \
  "${dotfiles_dir}/nvim/keymaps.lua" \
  "${dotfiles_dir}/nvim/lua/config/keymaps.lua"
do
  if [ -f "${candidate}" ]; then
    keymaps_source="${candidate}"
    break
  fi
done

if [ -z "${keymaps_source}" ]; then
  echo "30-editor: missing keymaps.lua in ${dotfiles_dir}/nvim (run 20-shell first)" >&2
  exit 1
fi

run_as_user "ln -sfn '${keymaps_source}' '${nvim_config_dir}/lua/config/keymaps.lua'"
chown -h "${user_name}:$(id -gn "${user_name}")" "${nvim_config_dir}/lua/config/keymaps.lua"

echo "30-editor: neovim + LazyVim in place"
