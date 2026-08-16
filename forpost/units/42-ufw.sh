#!/bin/bash
#
# 42-ufw.sh — firewall lockdown (SPEC §5, issue #13).
#
# default deny incoming / allow outgoing; only 42318/tcp (SSH), 443/tcp
# (the client-facing entry), and 9443/tcp (xform) are allowed. 443/udp stays closed deliberately —
# QUIC is blocked so clients fall back to TCP (SPEC §6). The SSH allow is
# always (re)asserted before enable: lockout guard.
#
# ufw itself is naturally idempotent: re-adding an existing rule is skipped,
# re-enabling an active firewall is a no-op.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

ufw default deny incoming
ufw default allow outgoing
ufw allow 42318/tcp comment 'forpost ssh'
ufw allow 443/tcp comment 'forpost entry'
ufw allow 9443/tcp comment 'forpost xform'

if ufw status | grep -q "^Status: active"; then
  echo "42-ufw: already active"
else
  ufw --force enable
  echo "42-ufw: enabled"
fi

ufw status verbose
