#!/bin/bash
#
# 00-stub.sh — skeleton placeholder unit (issue #8).
#
# Proves the pipeline end-to-end: the play transports the bundle, bootstrap.sh
# discovers and runs numbered units, and per-unit logs land in
# /var/log/forpost/. Replaced by the real baseline units (SPEC §4) in #9.
#
set -euo pipefail

# Same log dir as bootstrap.sh (overridable for local testing).
MARKER="${FORPOST_LOG_DIR:-/var/log/forpost}/.stub-ran"

echo "00-stub: forpost pipeline OK on $(uname -s)/$(dpkg --print-architecture 2>/dev/null || uname -m)"

# Idempotency guard: fixed content, so a re-run is a no-op.
if [ ! -f "${MARKER}" ]; then
  echo "ran" > "${MARKER}"
  echo "00-stub: marker written to ${MARKER}"
else
  echo "00-stub: marker already present, nothing to do"
fi
