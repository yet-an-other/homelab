#!/bin/bash
#
# 00-packages.sh — base package set (SPEC §4).
#
# Full replica of the cloud-init/cloud-init-ubuntu.yaml package list, plus the
# VPN-layer packages (nginx, ufw, unattended-upgrades). apt is naturally
# idempotent: with nothing to upgrade and every package installed, a re-run
# is a no-op.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

packages=(
  sudo
  zsh
  btop
  curl
  openssl
  git
  gcc
  unzip
  zip
  jq
  fontconfig
  ca-certificates
  tar
  xz-utils
  fzf
  nginx
  ufw
  unattended-upgrades
  acl
)

apt-get update
apt-get upgrade -y
apt-get install -y "${packages[@]}"
