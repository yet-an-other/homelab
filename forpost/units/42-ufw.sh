#!/bin/bash
#
# 42-ufw.sh — firewall: deny incoming, allow outgoing; only SSH (42318/tcp)
# and the VPN entry (443/tcp) are open. 443/udp stays closed deliberately —
# QUIC is blocked so clients fall back to TCP (SPEC §6).
# ufw commands are naturally idempotent ("Skipping adding existing rule").
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

ufw default deny incoming
ufw default allow outgoing

ufw allow 42318/tcp comment 'ssh'
ufw allow 443/tcp comment 'vless-reality'

# Defense in depth: drop a stale QUIC allow rule if one ever got in.
if ufw status | grep -qE '^443/udp\b.*ALLOW'; then
  ufw delete allow 443/udp
fi

ufw --force enable

ufw status verbose
