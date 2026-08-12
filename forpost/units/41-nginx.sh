#!/bin/bash
#
# 41-nginx.sh — place the rendered nginx configs, verify, reload.
#
# The play renders templates into /etc/nginx/.forpost-staging/ before this unit
# runs; this unit never templates — it places, verifies (nginx -t), restarts.
#
set -euo pipefail

STAGING="/etc/nginx/.forpost-staging"
CHANGED=0

place() {
  local src="$1"
  local dest="$2"
  if [ ! -f "${src}" ]; then
    echo "missing staged config: ${src} (the play renders it before this unit runs)" >&2
    exit 1
  fi
  if [ ! -f "${dest}" ] || ! cmp -s "${src}" "${dest}"; then
    install -m 0644 "${src}" "${dest}"
    CHANGED=1
    echo "placed ${dest}"
  fi
}

# ---- stream module (ubuntu ships it as a dynamic module) --------------------------
if ! nginx -V 2>&1 | grep -q 'with-stream'; then
  if [ ! -f /usr/lib/nginx/modules/ngx_stream_module.so ]; then
    apt-get update
    apt-get install -y libnginx-mod-stream
  fi
fi

install -d -m 0755 /etc/nginx/conf.d

place "${STAGING}/nginx.conf" /etc/nginx/nginx.conf
place "${STAGING}/default.conf" /etc/nginx/conf.d/default.conf
place "${STAGING}/fallback.conf" /etc/nginx/conf.d/fallback.conf

nginx -t

systemctl enable nginx
if ! systemctl is-active --quiet nginx; then
  systemctl start nginx
  echo "nginx started"
elif [ "${CHANGED}" -eq 1 ]; then
  systemctl reload nginx
  echo "nginx reloaded (config changed)"
else
  echo "nginx config unchanged; service already active"
fi

systemctl is-active --quiet nginx
