#!/bin/bash
# cert-matches-config.sh — Phase 1 feedback loop for "cert not re-issued after
# domain change" (diagnosing-bugs). RED while the cert deployed on the node
# does not cover the domain configured in the secret inventory; GREEN after a
# correct re-issuance. Read-only: inspects, never mutates.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
inventory="$repo_root/ansible/inventory.secret.yaml"

domain=$(awk '/^    forpost:/{f=1} f && /domain:/ {print $2; exit}' "$inventory" | tr -d '"')
host=$(awk '/^    forpost:/{f=1} f && /ansible_host:/ {print $2; exit}' "$inventory" | tr -d '"')
port=$(awk '/^    forpost:/{f=1} f && /ansible_port:/ {print $2; exit}' "$inventory")
port="${port:-42318}"
key=$(awk '/^  vars:/{v=1} v && /ansible_ssh_private_key_file:/ {print $2; exit}' "$inventory" | tr -d '"')
user=$(awk '/^    forpost:/{f=1} f && /ansible_user:/ {print $2; exit}' "$inventory" | tr -d '"')
user="${user:-ib}"

[ -n "$domain" ] && [ -n "$host" ] || { echo "RED: could not parse forpost domain/host from inventory"; exit 1; }

echo "configured domain : $domain"
echo "node              : $user@$host:$port"

sans=$(ssh -i "${key/#\~/$HOME}" -p "$port" -o ConnectTimeout=10 "$user@$host" \
  'openssl x509 -in /usr/ssl/fullchain.crt -noout -ext subjectAltName' 2>/dev/null \
  | grep -o 'DNS:[^ ,]*' | tr '\n' ' ')

echo "deployed cert SANs: $sans"

if grep -qw "$domain" <<< "$sans"; then
  echo "GREEN: deployed certificate covers $domain"
  exit 0
else
  echo "RED: deployed certificate does NOT cover $domain"
  exit 1
fi
