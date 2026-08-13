#!/bin/bash
#
# 31-tools.sh — eza + zmx (SPEC §4).
#
# eza: apt when the distro carries it, otherwise the latest upstream .deb for
# the architecture (the existing install_eza pattern from
# cloud-init/cloud-init-ubuntu.yaml). zmx: pinned tarball by architecture
# into /usr/local/bin (zmx names its arm build aarch64).
#
# Idempotency guards: `command -v` for both tools.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

zmx_version="0.6.0"

install_eza() {
  local arch
  local pattern
  local eza_deb_url

  if command -v eza >/dev/null 2>&1; then
    echo "31-tools: eza already installed"
    return 0
  fi

  if apt-cache show eza >/dev/null 2>&1; then
    apt-get install -y eza
    return 0
  fi

  arch="$(dpkg --print-architecture)"
  case "${arch}" in
    amd64)
      pattern="linux_amd64\\.deb$"
      ;;
    arm64)
      pattern="linux_arm64\\.deb$"
      ;;
    *)
      echo "31-tools: warning: unsupported architecture for automatic eza install: ${arch}" >&2
      return 0
      ;;
  esac

  eza_deb_url="$(curl -fsSL https://api.github.com/repos/eza-community/eza/releases/latest | jq -r --arg pattern "${pattern}" '.assets[] | select(.name | test($pattern)) | .browser_download_url' | head -n 1)"
  if [ -z "${eza_deb_url}" ] || [ "${eza_deb_url}" = "null" ]; then
    echo "31-tools: warning: unable to resolve latest eza package" >&2
    return 0
  fi

  curl -fsSL "${eza_deb_url}" -o /tmp/eza.deb
  apt-get install -y /tmp/eza.deb
  rm -f /tmp/eza.deb
}

install_zmx() {
  local arch
  local zmx_arch
  local tmpdir

  if command -v zmx >/dev/null 2>&1; then
    echo "31-tools: zmx already installed"
    return 0
  fi

  arch="$(dpkg --print-architecture)"
  case "${arch}" in
    amd64) zmx_arch="x86_64" ;;
    arm64) zmx_arch="aarch64" ;;
    *)
      echo "31-tools: warning: unsupported architecture for automatic zmx install: ${arch}" >&2
      return 0
      ;;
  esac

  tmpdir="$(mktemp -d)"
  curl -fsSL "https://zmx.sh/a/zmx-${zmx_version}-linux-${zmx_arch}.tar.gz" -o "${tmpdir}/zmx.tar.gz"
  tar -xzf "${tmpdir}/zmx.tar.gz" -C "${tmpdir}"
  install -m 0755 -o root -g root "${tmpdir}/zmx" /usr/local/bin/zmx
  rm -rf "${tmpdir}"
  echo "31-tools: zmx ${zmx_version} installed"
}

install_eza
install_zmx
