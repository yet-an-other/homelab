#!/bin/bash
#
# 31-tools.sh — eza (apt or latest .deb by arch) and zmx (tarball by arch).
# Guards: `command -v` for both tools.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

ZMX_VERSION="0.6.0"

install_eza() {
  local arch
  local pattern
  local eza_deb_url

  if command -v eza >/dev/null 2>&1; then
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
      echo "warning: unsupported architecture for automatic eza install: ${arch}" >&2
      return 0
      ;;
  esac

  eza_deb_url="$(curl -fsSL https://api.github.com/repos/eza-community/eza/releases/latest | jq -r --arg pattern "${pattern}" '.assets[] | select(.name | test($pattern)) | .browser_download_url' | head -n 1)"
  if [ -z "${eza_deb_url}" ] || [ "${eza_deb_url}" = "null" ]; then
    echo "warning: unable to resolve latest eza package" >&2
    return 0
  fi

  curl -fsSL "${eza_deb_url}" -o /tmp/eza.deb
  apt-get install -y /tmp/eza.deb
  rm -f /tmp/eza.deb
}

install_zmx() {
  local arch
  local zmx_arch

  if command -v zmx >/dev/null 2>&1; then
    return 0
  fi

  arch="$(dpkg --print-architecture)"
  case "${arch}" in
    amd64) zmx_arch="x86_64" ;;
    arm64) zmx_arch="aarch64" ;;
    *)
      echo "warning: unsupported architecture for zmx install: ${arch}" >&2
      return 0
      ;;
  esac

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  curl -fsSL "https://zmx.sh/a/zmx-${ZMX_VERSION}-linux-${zmx_arch}.tar.gz" -o "${tmp_dir}/zmx.tar.gz"
  tar -xzf "${tmp_dir}/zmx.tar.gz" -C "${tmp_dir}"
  install -m 0755 "${tmp_dir}/zmx" /usr/local/bin/zmx
  rm -rf "${tmp_dir}"
}

install_eza
install_zmx
