#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unit="${repo_root}/units/43-xform.sh"

tests_run=0
sandbox=""
release_api_override=""
arch_override="amd64"
fail_restart_for_broken=0
lock_deployment_state_on_broken=0

cleanup() {
  if [ -n "${sandbox}" ] && [ -d "${sandbox}" ]; then
    rm -rf "${sandbox}"
  fi
}
trap cleanup EXIT

fail() {
  echo "not ok - $*" >&2
  exit 1
}

assert_file_equals() {
  local expected="$1"
  local actual="$2"
  cmp -s "${expected}" "${actual}" || fail "${actual} does not match ${expected}"
}

assert_contains() {
  local expected="$1"
  local actual="$2"
  grep -Fq -- "${expected}" "${actual}" || fail "${actual} does not contain: ${expected}"
}

assert_empty() {
  local actual="$1"
  [ ! -s "${actual}" ] || fail "${actual} is not empty"
}

assert_missing() {
  local actual="$1"
  [ ! -e "${actual}" ] || fail "${actual} unexpectedly exists"
}

file_mtime() {
  if stat -f '%m' "$1" >/dev/null 2>&1; then
    stat -f '%m' "$1"
  else
    stat -c '%Y' "$1"
  fi
}

setup_sandbox() {
  cleanup
  release_api_override=""
  arch_override="amd64"
  fail_restart_for_broken=0
  lock_deployment_state_on_broken=0
  sandbox="$(mktemp -d)"
  mkdir -p "${sandbox}/release" "${sandbox}/bin" \
    "${sandbox}/app-state" "${sandbox}/deployment-state"

  cat > "${sandbox}/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ " $* " == *" http://xform.test/"* ]]; then
  grep -q 'healthy-release' "${XFORM_TEST_INSTALL_PATH}"
  exit
fi
exec /usr/bin/curl "$@"
EOF
  chmod +x "${sandbox}/bin/curl"

  cat > "${sandbox}/bin/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
case " $* " in
  *" xray.service "*|*" nginx.service "*) exit 97 ;;
esac
printf '%s\n' "$*" >> "${XFORM_TEST_SYSTEMCTL_LOG}"
if [ "$1" = restart ] && grep -q 'broken-release' "${XFORM_TEST_INSTALL_PATH}" 2>/dev/null; then
  printf '%s\n' 'state-migrated-by-broken-release' > "${XFORM_TEST_DB_PATH}"
  if [ "${XFORM_TEST_LOCK_DEPLOYMENT_STATE_ON_BROKEN}" = 1 ]; then
    chmod 0500 "${XFORM_TEST_DEPLOYMENT_STATE}"
  fi
  if [ "${XFORM_TEST_FAIL_RESTART_FOR_BROKEN}" = 1 ]; then
    exit 1
  fi
fi
EOF
  chmod +x "${sandbox}/bin/systemctl"
}

write_release() {
  local tag="$1"
  local arch="$2"
  local content="$3"
  local asset="xform-linux-${arch}"
  printf '%s\n' "${content}" > "${sandbox}/release/${asset}"
  chmod +x "${sandbox}/release/${asset}"
  (
    cd "${sandbox}/release"
    sha256sum "${asset}" > checksums.txt
  )
  cat > "${sandbox}/release/release.json" <<EOF
{
  "tag_name": "${tag}",
  "draft": false,
  "prerelease": false,
  "assets": [
    {"name": "checksums.txt", "browser_download_url": "file://${sandbox}/release/checksums.txt"},
    {"name": "${asset}", "browser_download_url": "file://${sandbox}/release/${asset}"}
  ]
}
EOF
}

run_unit() {
  XFORM_HOST_SETUP=0 \
  XFORM_LOCK_ENABLED=0 \
  XFORM_INSTALL_PATH="${sandbox}/installed/xform" \
  XFORM_APP_STATE_DIR="${sandbox}/app-state" \
  XFORM_DEPLOYMENT_STATE_DIR="${sandbox}/deployment-state" \
  XFORM_DB_PATH="${sandbox}/app-state/xform.db" \
  XFORM_RELEASE_API="${release_api_override:-file://${sandbox}/release/release.json}" \
  XFORM_ARCH="${arch_override}" \
  XFORM_CURL="${sandbox}/bin/curl" \
  XFORM_SYSTEMCTL="${sandbox}/bin/systemctl" \
  XFORM_TEST_INSTALL_PATH="${sandbox}/installed/xform" \
  XFORM_TEST_DB_PATH="${sandbox}/app-state/xform.db" \
  XFORM_TEST_DEPLOYMENT_STATE="${sandbox}/deployment-state" \
  XFORM_TEST_FAIL_RESTART_FOR_BROKEN="${fail_restart_for_broken}" \
  XFORM_TEST_LOCK_DEPLOYMENT_STATE_ON_BROKEN="${lock_deployment_state_on_broken}" \
  XFORM_TEST_SYSTEMCTL_LOG="${sandbox}/systemctl.log" \
  XFORM_HEALTH_URL="http://xform.test/" \
  XFORM_HEALTH_ATTEMPTS=1 \
  XFORM_HEALTH_DELAY=0 \
  XFORM_SERVICE=xform.service \
  bash "${unit}"
}

test_fresh_install_selects_and_verifies_latest_release() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"

  run_unit

  assert_file_equals "${sandbox}/release/xform-linux-amd64" "${sandbox}/installed/xform"
  assert_contains "v1.2.3" "${sandbox}/deployment-state/installed-release"
  assert_missing "${sandbox}/app-state/installed-release"
  assert_missing "${sandbox}/app-state/rejected-version"
  assert_contains "restart xform.service" "${sandbox}/systemctl.log"
  echo "ok - fresh install selects and verifies latest release"
}

test_matching_release_is_a_noop() {
  local release_mtime
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"
  run_unit
  : > "${sandbox}/systemctl.log"
  touch -t 200001010000 "${sandbox}/deployment-state/installed-release"
  release_mtime="$(file_mtime "${sandbox}/deployment-state/installed-release")"

  run_unit

  assert_empty "${sandbox}/systemctl.log"
  assert_contains "v1.2.3" "${sandbox}/deployment-state/installed-release"
  [ "$(file_mtime "${sandbox}/deployment-state/installed-release")" = "${release_mtime}" ] ||
    fail "matching release rewrote installed-release"
  echo "ok - matching release is a no-op"
}

test_new_tag_restarts_even_when_binary_is_identical() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-identical"
  run_unit
  : > "${sandbox}/systemctl.log"
  write_release "v1.3.0" "amd64" "healthy-release-identical"

  run_unit

  assert_contains "stop xform.service" "${sandbox}/systemctl.log"
  assert_contains "restart xform.service" "${sandbox}/systemctl.log"
  assert_contains "v1.3.0" "${sandbox}/deployment-state/installed-release"
  echo "ok - new tag restarts even when binary is identical"
}

test_same_tag_ignores_mutated_upstream_asset() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-original"
  run_unit
  cp "${sandbox}/installed/xform" "${sandbox}/old-xform"
  : > "${sandbox}/systemctl.log"
  write_release "v1.2.3" "amd64" "healthy-release-mutated"

  run_unit

  assert_file_equals "${sandbox}/old-xform" "${sandbox}/installed/xform"
  assert_empty "${sandbox}/systemctl.log"
  echo "ok - same tag ignores mutated upstream asset"
}

test_update_preserves_previous_binary_and_state() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"
  run_unit
  cp "${sandbox}/installed/xform" "${sandbox}/old-xform"
  printf '%s\n' "state-v1" > "${sandbox}/app-state/xform.db"
  write_release "v1.3.0" "amd64" "healthy-release-v1.3.0"

  run_unit

  assert_file_equals "${sandbox}/release/xform-linux-amd64" "${sandbox}/installed/xform"
  assert_file_equals "${sandbox}/old-xform" "${sandbox}/installed/xform.prev"
  assert_contains "state-v1" "${sandbox}/app-state/xform.db"
  assert_contains "state-v1" "${sandbox}/deployment-state/xform.db.prev"
  assert_contains "v1.3.0" "${sandbox}/deployment-state/installed-release"
  echo "ok - update preserves previous binary and state"
}

test_failed_update_rolls_back_and_quarantines_release() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"
  run_unit
  cp "${sandbox}/installed/xform" "${sandbox}/old-xform"
  printf '%s\n' "state-v1" > "${sandbox}/app-state/xform.db"
  write_release "v1.3.0" "amd64" "broken-release-v1.3.0"

  run_unit

  assert_file_equals "${sandbox}/old-xform" "${sandbox}/installed/xform"
  assert_contains "state-v1" "${sandbox}/app-state/xform.db"
  assert_contains "v1.2.3" "${sandbox}/deployment-state/installed-release"
  assert_contains "v1.3.0" "${sandbox}/deployment-state/rejected-version"
  echo "ok - failed update rolls back and quarantines release"
}

test_failed_candidate_restart_rolls_back() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"
  run_unit
  cp "${sandbox}/installed/xform" "${sandbox}/old-xform"
  printf '%s\n' "state-v1" > "${sandbox}/app-state/xform.db"
  write_release "v1.3.0" "amd64" "broken-release-v1.3.0"
  fail_restart_for_broken=1

  run_unit

  assert_file_equals "${sandbox}/old-xform" "${sandbox}/installed/xform"
  assert_contains "state-v1" "${sandbox}/app-state/xform.db"
  assert_contains "v1.3.0" "${sandbox}/deployment-state/rejected-version"
  echo "ok - failed candidate restart rolls back"
}

test_quarantine_write_failure_is_not_reported_as_recovered() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"
  run_unit
  cp "${sandbox}/installed/xform" "${sandbox}/old-xform"
  write_release "v1.3.0" "amd64" "broken-release-v1.3.0"
  lock_deployment_state_on_broken=1

  if run_unit; then
    chmod 0700 "${sandbox}/deployment-state"
    fail "rollback unexpectedly succeeded without a quarantine marker"
  fi
  chmod 0700 "${sandbox}/deployment-state"

  assert_file_equals "${sandbox}/old-xform" "${sandbox}/installed/xform"
  assert_missing "${sandbox}/deployment-state/rejected-version"
  echo "ok - quarantine write failure is not reported as recovered"
}

test_backup_failure_restarts_previous_service() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"
  run_unit
  cp "${sandbox}/installed/xform" "${sandbox}/old-xform"
  printf '%s\n' "state-v1" > "${sandbox}/app-state/xform.db"
  write_release "v1.3.0" "amd64" "healthy-release-v1.3.0"
  : > "${sandbox}/systemctl.log"
  chmod 0500 "${sandbox}/deployment-state"

  if run_unit; then
    chmod 0700 "${sandbox}/deployment-state"
    fail "update unexpectedly survived a state-backup failure"
  fi
  chmod 0700 "${sandbox}/deployment-state"

  assert_file_equals "${sandbox}/old-xform" "${sandbox}/installed/xform"
  assert_contains "stop xform.service" "${sandbox}/systemctl.log"
  assert_contains "start xform.service" "${sandbox}/systemctl.log"
  assert_missing "${sandbox}/deployment-state/rejected-version"
  echo "ok - backup failure restarts previous service"
}

test_failed_update_removes_new_state_when_none_existed() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"
  run_unit
  assert_missing "${sandbox}/app-state/xform.db"
  write_release "v1.3.0" "amd64" "broken-release-v1.3.0"

  run_unit >/dev/null 2>&1

  assert_missing "${sandbox}/app-state/xform.db"
  echo "ok - failed update removes state created by rejected release"
}

test_quarantined_release_is_skipped() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"
  run_unit
  write_release "v1.3.0" "amd64" "broken-release-v1.3.0"
  run_unit >/dev/null 2>&1
  : > "${sandbox}/systemctl.log"

  run_unit

  assert_empty "${sandbox}/systemctl.log"
  assert_contains "v1.2.3" "${sandbox}/deployment-state/installed-release"
  assert_contains "v1.3.0" "${sandbox}/deployment-state/rejected-version"
  echo "ok - quarantined release is skipped"
}

test_release_discovery_outage_keeps_working_installation() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"
  run_unit
  cp "${sandbox}/installed/xform" "${sandbox}/old-xform"
  : > "${sandbox}/systemctl.log"
  release_api_override="file://${sandbox}/release/missing.json"

  run_unit

  assert_file_equals "${sandbox}/old-xform" "${sandbox}/installed/xform"
  assert_empty "${sandbox}/systemctl.log"
  assert_contains "v1.2.3" "${sandbox}/deployment-state/installed-release"
  echo "ok - release discovery outage keeps working installation"
}

test_initial_release_discovery_outage_fails() {
  setup_sandbox
  release_api_override="file://${sandbox}/release/missing.json"

  if run_unit; then
    fail "initial install unexpectedly survived release discovery outage"
  fi

  assert_missing "${sandbox}/installed/xform"
  echo "ok - initial release discovery outage fails"
}

test_checksum_mismatch_keeps_working_installation() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"
  run_unit
  cp "${sandbox}/installed/xform" "${sandbox}/old-xform"
  write_release "v1.3.0" "amd64" "healthy-release-v1.3.0"
  printf '%s\n' "tampered-release" > "${sandbox}/release/xform-linux-amd64"
  : > "${sandbox}/systemctl.log"

  run_unit

  assert_file_equals "${sandbox}/old-xform" "${sandbox}/installed/xform"
  assert_empty "${sandbox}/systemctl.log"
  assert_missing "${sandbox}/deployment-state/rejected-version"
  echo "ok - checksum mismatch keeps working installation"
}

test_newer_release_replaces_quarantined_release() {
  setup_sandbox
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"
  run_unit
  write_release "v1.3.0" "amd64" "broken-release-v1.3.0"
  run_unit >/dev/null 2>&1
  write_release "v1.4.0" "amd64" "healthy-release-v1.4.0"

  run_unit

  assert_contains "v1.4.0" "${sandbox}/deployment-state/installed-release"
  assert_missing "${sandbox}/deployment-state/rejected-version"
  echo "ok - newer release replaces quarantined release"
}

test_arm64_release_is_selected() {
  setup_sandbox
  arch_override="aarch64"
  write_release "v1.2.3" "arm64" "healthy-release-v1.2.3-arm64"

  run_unit

  assert_file_equals "${sandbox}/release/xform-linux-arm64" "${sandbox}/installed/xform"
  echo "ok - arm64 release is selected"
}

test_unsupported_architecture_fails() {
  setup_sandbox
  arch_override="riscv64"
  write_release "v1.2.3" "amd64" "healthy-release-v1.2.3"

  if run_unit; then
    fail "unsupported architecture unexpectedly succeeded"
  fi

  assert_missing "${sandbox}/installed/xform"
  echo "ok - unsupported architecture fails"
}

run_test() {
  tests_run=$((tests_run + 1))
  "$1"
}

run_test test_fresh_install_selects_and_verifies_latest_release
run_test test_matching_release_is_a_noop
run_test test_new_tag_restarts_even_when_binary_is_identical
run_test test_same_tag_ignores_mutated_upstream_asset
run_test test_update_preserves_previous_binary_and_state
run_test test_failed_update_rolls_back_and_quarantines_release
run_test test_failed_candidate_restart_rolls_back
run_test test_quarantine_write_failure_is_not_reported_as_recovered
run_test test_backup_failure_restarts_previous_service
run_test test_failed_update_removes_new_state_when_none_existed
run_test test_quarantined_release_is_skipped
run_test test_release_discovery_outage_keeps_working_installation
run_test test_initial_release_discovery_outage_fails
run_test test_checksum_mismatch_keeps_working_installation
run_test test_newer_release_replaces_quarantined_release
run_test test_arm64_release_is_selected
run_test test_unsupported_architecture_fails

echo "${tests_run} tests passed"
