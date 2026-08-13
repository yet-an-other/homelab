#!/bin/bash
#
# install-xray.sh — install, upgrade, or remove Xray-core on Ubuntu/Debian.
#
# A thin, idempotent wrapper around the official XTLS/Xray-install
# install-release.sh. Binary placement, the systemd units, geoip/geosite
# data, checksum verification, version handling, and service enable/start are
# ALL delegated to the upstream script — this wrapper only adds preflight
# checks, a small CLI, and the "download then run" (never `curl | bash`)
# invocation model.
#
# The official installer seeds /usr/local/etc/xray/config.json with "{}" and
# enables + starts xray.service. Drop your real config there and restart.
#
# Usage:
#   sudo install-xray.sh                  # install or upgrade to latest release
#   sudo install-xray.sh --version v1.8.24 # install a pinned release
#   sudo install-xray.sh --geodata         # refresh enhanced geoip/geosite data
#   sudo install-xray.sh --remove          # uninstall xray (keeps config & logs)
#   sudo install-xray.sh --remove --purge  # uninstall + remove config & logs
#   install-xray.sh --help
#
set -euo pipefail

INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
CONFIG_PATH="/usr/local/etc/xray/config.json"

# Global so the EXIT trap can reference it safely under `set -u`.
INSTALLER_TMP=""

err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
info() { printf '\033[32minfo:\033[0m %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: sudo install-xray.sh [ACTION]

Thin, idempotent wrapper around the official XTLS/Xray-install installer.
With no action, installs or upgrades Xray-core to the latest release and
enables the systemd service.

Actions:
  (default)                 Install or upgrade to the latest Xray-core release
  --version <tag>           Install a specific release, e.g. --version v1.8.24
  --geodata                 Refresh enhanced geoip.dat/geosite.dat (Loyalsoldier)
  --remove                  Uninstall Xray (keeps config & logs)
  --remove --purge          Uninstall Xray AND remove config & logs
  -h, --help                Show this help

Requires root, systemd, and a Debian/Ubuntu family host.
EOF
}

cleanup() {
  if [ -n "$INSTALLER_TMP" ]; then
    rm -f "$INSTALLER_TMP"
  fi
}
trap cleanup EXIT

# ---- preflight (fail fast, before any network use) -------------------------
require_root() {
  if [ "${EUID}" -ne 0 ]; then
    err "this script must be run as root (try: sudo $0)"
    exit 1
  fi
}

require_systemd() {
  if [ ! -d /run/systemd/system ]; then
    err "systemd is required; this host does not appear to use systemd."
    exit 1
  fi
}

require_debian_family() {
  if [ ! -f /etc/os-release ]; then
    err "cannot determine OS: /etc/os-release is missing."
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian | ubuntu | linuxmint) return 0 ;;
  esac
  case "${ID_LIKE:-}" in
    *debian*) return 0 ;;
  esac
  err "only Debian/Ubuntu family hosts are supported (detected: ${ID:-unknown})."
  exit 1
}

# ---- fetch the official installer to a temp file (never curl | bash) --------
fetch_installer() {
  if ! command -v curl >/dev/null 2>&1; then
    err "'curl' is required to download the installer (apt -y install curl)."
    exit 1
  fi
  INSTALLER_TMP="$(mktemp)"
  if ! curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_TMP"; then
    err "failed to download the official installer from $INSTALLER_URL."
    rm -f "$INSTALLER_TMP"
    exit 1
  fi
}

run_installer() {
  fetch_installer
  bash "$INSTALLER_TMP" "$@"
}

post_install_status() {
  info "xray-core install/upgrade complete."
  info "config: $CONFIG_PATH  (replace the seeded '{}' and 'systemctl restart xray')"
  if systemctl -q is-active xray; then
    info "xray.service is active."
  else
    err "xray.service is not active — see 'journalctl -u xray -e'."
  fi
}

# ---- argument parsing -------------------------------------------------------
main() {
  local mode="install"
  local version=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --version)
        if [ -z "${2:-}" ]; then
          err "--version requires a tag (e.g. --version v1.8.24)."
          exit 2
        fi
        version="$2"
        shift 2
        ;;
      --geodata)
        if [ "$mode" != "install" ]; then
          err "--geodata cannot be combined with --remove."
          exit 2
        fi
        mode="install-geodata"
        shift
        ;;
      --remove)
        if [ "$mode" != "install" ]; then
          err "--remove cannot be combined with --geodata."
          exit 2
        fi
        mode="remove"
        shift
        ;;
      --purge)
        if [ "$mode" != "remove" ]; then
          err "--purge must be used together with --remove."
          exit 2
        fi
        mode="remove-purge"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        err "unknown option: $1"
        usage >&2
        exit 2
        ;;
    esac
  done

  if [ "$#" -gt 0 ]; then
    err "unexpected arguments: $*"
    exit 2
  fi

  if [ -n "$version" ] && [ "$mode" != "install" ]; then
    err "--version only applies to the default install action."
    exit 2
  fi

  require_root
  require_systemd
  require_debian_family

  local args=()
  case "$mode" in
    install) args=("install") ;;
    install-geodata) args=("install-geodata") ;;
    remove) args=("remove") ;;
    remove-purge) args=("remove" "--purge") ;;
  esac
  if [ -n "$version" ]; then
    args+=("--version" "$version")
  fi

  info "delegating to official installer: ${args[*]}"
  run_installer "${args[@]}"

  if [ "$mode" == "install" ]; then
    post_install_status
  fi
}

main "$@"
