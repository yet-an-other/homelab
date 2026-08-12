#!/bin/bash
#
# 00-packages.sh — base packages for the forpost node.
# Mirrors cloud-init/cloud-init-ubuntu.yaml, plus the VPN layer packages.
# apt is naturally idempotent.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y
apt-get install -y \
  sudo \
  zsh \
  btop \
  curl \
  openssl \
  git \
  gcc \
  unzip \
  zip \
  jq \
  fontconfig \
  ca-certificates \
  tar \
  xz-utils \
  fzf \
  nginx \
  ufw \
  unattended-upgrades \
  logrotate
