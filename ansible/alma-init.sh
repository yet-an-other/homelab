#!/bin/bash

# Remove password for sudo for main user
#
echo "ib ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/ib
sudo chmod 440 /etc/sudoers.d/ib

# install addition repositories for AlmaLinux
#
sudo dnf install -y epel-release
sudo /usr/bin/crb enable
sudo dnf makecache

# update system
#
sudo dnf update -y

# install basic tools
#
sudo dnf install -y qemu-guest-agent neovim git btop unzip zip jq policycoreutils-python-utils tar openssl

# allow qemu guest agent execute permissions
#
sudo sed -i '/FILTER_RPC_ARGS="--allow/s/^/#/g' /etc/sysconfig/qemu-ga
sudo semanage permissive -a virt_qemu_ga_t

# configure qemu-guest-agent to start on boot
#
sudo systemctl enable --now qemu-guest-agent

# set neovim as default editor
#
echo "export EDITOR='nvim'" >> ~/.bashrc

# install oh-my-bash
#
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" "" --unattended

# remove time from bash prompt
#
sed -i 's/THEME_SHOW_CLOCK=${THEME_SHOW_CLOCK:-"true"}/THEME_SHOW_CLOCK=${THEME_SHOW_CLOCK:-"false"}/g' ~/.oh-my-bash/themes/font/font.theme.sh

# install eza
#
curl -L https://github.com/eza-community/eza/releases/download/v0.23.4/eza_x86_64-unknown-linux-gnu.zip -o /tmp/eza.zip
unzip /tmp/eza.zip -d /tmp/
sudo mv /tmp/eza /usr/bin/eza
sudo chmod +x /usr/bin/eza
rm /tmp/eza.zip

# add aliases
#
echo " " >> ~/.bashrc
echo "# eza aliases" >> ~/.bashrc
echo "alias l=\"eza -lah --group-directories-first --icons=auto\"" >> ~/.bashrc
echo "alias lt=\"eza -a --tree --level=2 --long --icons --git --group-directories-first\"" >> ~/.bashrc
echo "alias sl=\"sudo eza -lah --group-directories-first --icons=auto\"" >> ~/.bashrc
echo "alias slt=\"sudo eza -a --tree --level=2 --long --icons --git --group-directories-first\"" >> ~/.bashrc
echo " " >> ~/.bashrc
echo "# directory aliases" >> ~/.bashrc
echo "alias ..=\"cd ..\"" >> ~/.bashrc
echo "alias ...=\"cd ../..\"" >> ~/.bashrc
echo "alias ....=\"cd ../../..\"" >> ~/.bashrc

