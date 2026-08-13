#!/bin/bash
#
# bootstrap.sh — forpost node entrypoint.
#
# Runs units/[0-9][0-9]-*.sh in lexical order; each unit is idempotent and
# individually re-runnable. Per-unit logs go to /var/log/forpost/<unit>.log.
#
# Usage:
#   bootstrap.sh                  # full run
#   bootstrap.sh --only 40        # one unit by number (or name: --only xray)
#   bootstrap.sh --from 40        # 40 and everything after it (VPN layer iteration)
#
set -euo pipefail

FORPOST_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITS_DIR="${FORPOST_HOME}/units"
LOG_DIR="${FORPOST_LOG_DIR:-/var/log/forpost}"

ONLY=""
FROM=""

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--only <NN|name>] [--from <NN>]

Runs units/[0-9][0-9]-*.sh in lexical order.
  --only <NN|name>   run a single unit (e.g. --only 40, --only xray, --only 40-xray)
  --from  <NN>       run from unit NN onwards (e.g. --from 40 for the VPN layer)
Logs: /var/log/forpost/<unit>.log
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --only)
      ONLY="${2:?--only requires a value}"
      shift 2
      ;;
    --from)
      FROM="${2:?--from requires a value}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -n "${ONLY}" ] && [ -n "${FROM}" ]; then
  echo "error: --only and --from are mutually exclusive" >&2
  exit 2
fi

if [ -n "${FROM}" ] && ! [[ "${FROM}" =~ ^[0-9]+$ ]]; then
  echo "error: --from expects a unit number (NN), got: ${FROM}" >&2
  exit 2
fi

should_run() {
  local name="$1"
  local nn="${1:0:2}"
  local bare="${name%.sh}"
  bare="${bare#??-}"
  if [ -n "${ONLY}" ]; then
    case "${ONLY}" in
      "${nn}" | "${name}" | "${name%.sh}" | "${bare}") return 0 ;;
      *) return 1 ;;
    esac
  fi
  if [ -n "${FROM}" ]; then
    [ "$((10#${nn}))" -ge "$((10#${FROM}))" ]
    return
  fi
  return 0
}

mkdir -p "${LOG_DIR}"

shopt -s nullglob
units=("${UNITS_DIR}"/[0-9][0-9]-*.sh)
if [ "${#units[@]}" -eq 0 ]; then
  echo "error: no units found in ${UNITS_DIR}" >&2
  exit 1
fi

ran=0
for unit in "${units[@]}"; do
  name="$(basename "${unit}")"
  if ! should_run "${name}"; then
    echo "skip ${name}"
    continue
  fi
  ran=1
  log="${LOG_DIR}/${name%.sh}.log"
  echo "==> ${name} (log: ${log})"
  bash "${unit}" 2>&1 | tee "${log}"
done

if [ "${ran}" -eq 0 ]; then
  echo "error: no units matched the selector" >&2
  exit 1
fi

echo "forpost bootstrap complete."
