#!/bin/bash
#
# 41-nginx.sh — the nginx entry (SPEC §5/§7, issue #13).
#
# Ubuntu ships the stream module separately (libnginx-mod-stream); the http
# block, SNI-map stream block, 418 default site and fallback vhost are
# rendered by the play into staging and PLACED by this unit — units place,
# verify, restart (SPEC §2). Validates with nginx -t before touching the
# running service; reloads only when a placed file changed.
#
# Idempotency guards: package presence, content compares per file.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

forpost_home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
staging="${forpost_home}/nginx"

changed=0

# --- stream module ----------------------------------------------------------

if ! dpkg -s libnginx-mod-stream >/dev/null 2>&1; then
  apt-get update
  apt-get install -y libnginx-mod-stream
  changed=1
fi

# --- cert sanity --------------------------------------------------------------

if [ ! -s /usr/ssl/fullchain.crt ] || [ ! -s /usr/ssl/certificate.key ]; then
  echo "41-nginx: /usr/ssl cert missing — the play issues it before units run" >&2
  exit 1
fi

# --- place rendered confs -----------------------------------------------------

place() {
  local src="$1"
  local dest="$2"
  if [ ! -f "${src}" ]; then
    echo "41-nginx: missing staged file: ${src}" >&2
    exit 1
  fi
  if [ -f "${dest}" ] && cmp -s "${src}" "${dest}"; then
    echo "41-nginx: ${dest} already in place"
  else
    install -m 0644 -o root -g root "${src}" "${dest}"
    changed=1
    echo "41-nginx: placed ${dest}"
  fi
}

install -d -m 0755 /etc/nginx/conf.d
place "${staging}/nginx.conf" /etc/nginx/nginx.conf
place "${staging}/default.conf" /etc/nginx/conf.d/default.conf
place "${staging}/fallback.conf" /etc/nginx/conf.d/fallback.conf

# --- validate + (re)start -----------------------------------------------------

nginx -t

systemctl enable nginx
if ! systemctl is-active --quiet nginx; then
  systemctl start nginx
  echo "41-nginx: nginx started"
elif [ "${changed}" -eq 1 ]; then
  systemctl reload nginx
  echo "41-nginx: config changed, nginx reloaded"
else
  echo "41-nginx: config unchanged, nginx left running"
fi
