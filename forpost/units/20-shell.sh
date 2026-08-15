#!/bin/bash
#
# 20-shell.sh — zsh environment (SPEC §4).
#
# oh-my-zsh + powerlevel10k + zsh-syntax-highlighting, dotfiles clone, and
# the .zshrc / .p10k.zsh symlinks. Replica of the shell section of
# cloud-init/cloud-init-ubuntu.yaml.
#
# Idempotency guard: clones are skipped when the target .git dir exists
# (the existing `[ ! -d …/.git ]` pattern); symlinks are `ln -sfn`.
#
set -euo pipefail

user_name="ib"
user_home="/home/${user_name}"
dotfiles_dir="${user_home}/.dotfiles"
zshrc_source="${dotfiles_dir}/zsh-ssh/.zshrc"
p10k_source="${dotfiles_dir}/zsh-ssh/.p10k.zsh"

run_as_user() {
  sudo -u "${user_name}" -H bash -lc "$1"
}

if [ ! -d "${user_home}/.oh-my-zsh/.git" ]; then
  run_as_user "git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git '${user_home}/.oh-my-zsh'"
fi

install -d -m 0755 -o "${user_name}" -g "$(id -gn "${user_name}")" \
  "${user_home}/.oh-my-zsh/custom/themes" \
  "${user_home}/.oh-my-zsh/custom/plugins"

if [ ! -d "${user_home}/.oh-my-zsh/custom/themes/powerlevel10k/.git" ]; then
  run_as_user "git clone --depth 1 https://github.com/romkatv/powerlevel10k.git '${user_home}/.oh-my-zsh/custom/themes/powerlevel10k'"
fi

if [ ! -d "${user_home}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/.git" ]; then
  run_as_user "git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting.git '${user_home}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting'"
fi

if [ ! -d "${dotfiles_dir}/.git" ]; then
  run_as_user "git clone --branch main --depth 1 https://github.com/yet-an-other/dotfiles.git '${dotfiles_dir}'"
fi

for source in "${zshrc_source}" "${p10k_source}"; do
  if [ ! -f "${source}" ]; then
    echo "20-shell: missing dotfiles source: ${source}" >&2
    exit 1
  fi
done

run_as_user "ln -sfn '${zshrc_source}' '${user_home}/.zshrc'"
run_as_user "ln -sfn '${p10k_source}' '${user_home}/.p10k.zsh'"
chown -h "${user_name}:$(id -gn "${user_name}")" "${user_home}/.zshrc" "${user_home}/.p10k.zsh"

echo "20-shell: zsh environment in place"
