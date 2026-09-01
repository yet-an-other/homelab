#!/bin/bash
#
# 43-xform.sh — install and supervise the xform monitoring and roster panel.
#
# Resolves the latest stable upstream release during every invocation, verifies
# its checksum, installs it atomically, and accepts it only after a loopback
# HTTP smoke test. The service itself stays on loopback behind nginx.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

install_path="${XFORM_INSTALL_PATH:-/usr/local/bin/xform}"
app_state_dir="${XFORM_APP_STATE_DIR:-/var/lib/xform}"
deployment_state_dir="${XFORM_DEPLOYMENT_STATE_DIR:-/var/lib/forpost/xform}"
db_path="${XFORM_DB_PATH:-${app_state_dir}/xform.db}"
db_backup_path="${XFORM_DB_BACKUP_PATH:-${deployment_state_dir}/xform.db.prev}"
release_api="${XFORM_RELEASE_API:-https://api.github.com/repos/yet-an-other/xform/releases/latest}"
service="${XFORM_SERVICE:-xform.service}"
curl_cmd="${XFORM_CURL:-curl}"
systemctl_cmd="${XFORM_SYSTEMCTL:-systemctl}"
health_attempts="${XFORM_HEALTH_ATTEMPTS:-20}"
health_delay="${XFORM_HEALTH_DELAY:-1}"
host_setup="${XFORM_HOST_SETUP:-1}"
lock_enabled="${XFORM_LOCK_ENABLED:-1}"
forpost_home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
service_staging="${XFORM_SERVICE_STAGING:-${forpost_home}/xform/xform.service}"
service_unit="${XFORM_SERVICE_UNIT:-/etc/systemd/system/xform.service}"
xray_config="${XFORM_XRAY_CONFIG_PATH:-/usr/local/etc/xray/config.json}"
xray_config_dir="$(dirname "${xray_config}")"
xray_user="${XFORM_XRAY_USER:-nobody}"
service_changed=0
service_checksum=""
temp_dir=""

installed_release_file="${deployment_state_dir}/installed-release"
rejected_version_file="${deployment_state_dir}/rejected-version"
active_service_checksum_file="${deployment_state_dir}/active-service-unit-checksum"

log() {
  echo "43-xform: $*"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  if [ -n "${temp_dir}" ] && [ -d "${temp_dir}" ]; then
    rm -rf "${temp_dir}"
  fi
}
trap cleanup EXIT

architecture() {
  local machine="${XFORM_ARCH:-}"
  if [ -z "${machine}" ]; then
    machine="$(dpkg --print-architecture)" || return 1
  fi
  case "${machine}" in
    amd64 | x86_64) echo amd64 ;;
    arm64 | aarch64) echo arm64 ;;
    *)
      echo "43-xform: unsupported architecture ${machine}" >&2
      return 1
      ;;
  esac
}

healthy() {
  local urls url attempt
  if [ -n "${XFORM_HEALTH_URL:-}" ]; then
    urls="${XFORM_HEALTH_URL}"
  else
    urls="http://127.0.0.1:9090/api/v1/healthz http://127.0.0.1:9090/api/v1/server"
  fi

  attempt=1
  while [ "${attempt}" -le "${health_attempts}" ]; do
    for url in ${urls}; do
      if "${curl_cmd}" -fsS -o /dev/null "${url}"; then
        return 0
      fi
    done
    if [ "${attempt}" -lt "${health_attempts}" ]; then
      sleep "${health_delay}"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

ensure_running() {
  if [ "${host_setup}" = 1 ] &&
    { [ "${service_changed}" -eq 1 ] || ! "${systemctl_cmd}" is-active --quiet "${service}"; }; then
    "${systemctl_cmd}" restart "${service}" || return 1
  fi
  if healthy; then
    return 0
  fi
  "${systemctl_cmd}" restart "${service}" || return 1
  healthy
}

write_value() {
  local value="$1"
  local destination="$2"
  local value_temp
  if [ -f "${destination}" ] && [ "$(cat "${destination}")" = "${value}" ]; then
    return 0
  fi
  value_temp="$(mktemp "${deployment_state_dir}/.state.XXXXXX")" || return 1
  if ! printf '%s\n' "${value}" > "${value_temp}" ||
    ! chmod 0600 "${value_temp}" ||
    ! mv -f "${value_temp}" "${destination}"; then
    rm -f "${value_temp}"
    return 1
  fi
}

record_active_service() {
  if [ "${host_setup}" != 1 ]; then
    return 0
  fi
  if [ -z "${service_checksum}" ]; then
    echo "43-xform: service unit checksum was not collected" >&2
    return 1
  fi
  write_value "${service_checksum}" "${active_service_checksum_file}" || return 1
  if [ "${service_changed}" -eq 1 ]; then
    log "activated service unit ${service_unit}"
  fi
}

atomic_copy() {
  local source="$1"
  local destination="$2"
  local copy_temp
  copy_temp="$(mktemp "$(dirname "${destination}")/.copy.XXXXXX")" || return 1
  if ! cp -p "${source}" "${copy_temp}" || ! mv -f "${copy_temp}" "${destination}"; then
    rm -f "${copy_temp}"
    return 1
  fi
}

restore_database() {
  local had_database="$1"
  if [ "${had_database}" -eq 1 ]; then
    atomic_copy "${db_backup_path}" "${db_path}"
  else
    rm -f "${db_path}"
  fi
}

setup_host() {
  local missing_packages package xform_entry xform_home xform_shell
  missing_packages=""
  for package in curl jq acl; do
    if ! dpkg -s "${package}" >/dev/null 2>&1; then
      missing_packages="${missing_packages} ${package}"
    fi
  done
  if [ -n "${missing_packages}" ]; then
    apt-get update
    # shellcheck disable=SC2086 # intentional word splitting of package names
    apt-get install -y ${missing_packages}
  fi

  if ! getent group xform >/dev/null; then
    groupadd --system xform
  fi
  if ! id -u xform >/dev/null 2>&1; then
    useradd --system --gid xform --home-dir "${app_state_dir}" --shell /usr/sbin/nologin xform
  else
    xform_entry="$(getent passwd xform)"
    xform_home="$(printf '%s' "${xform_entry}" | cut -d: -f6)"
    xform_shell="$(printf '%s' "${xform_entry}" | cut -d: -f7)"
    if [ "$(id -gn xform)" != xform ] || [ "${xform_home}" != "${app_state_dir}" ] ||
      [ "${xform_shell}" != /usr/sbin/nologin ]; then
      usermod --gid xform --home "${app_state_dir}" --shell /usr/sbin/nologin xform
    fi
  fi
  install -d -m 0750 -o xform -g xform "${app_state_dir}"
  install -d -m 0750 -o root -g root "${deployment_state_dir}"

  if [ ! -f "${service_staging}" ]; then
    echo "43-xform: missing staged service: ${service_staging}" >&2
    return 1
  fi
  if [ -f "${service_unit}" ] && cmp -s "${service_staging}" "${service_unit}"; then
    log "${service_unit} already in place"
  else
    install -m 0644 -o root -g root "${service_staging}" "${service_unit}"
    "${systemctl_cmd}" daemon-reload
    service_changed=1
    log "placed ${service_unit}"
  fi
  service_checksum="$(sha256sum "${service_unit}" | awk '{print $1}')" || return 1
  if [ ! -s "${active_service_checksum_file}" ] ||
    [ "$(cat "${active_service_checksum_file}")" != "${service_checksum}" ]; then
    service_changed=1
  fi

  if [ ! -f "${xray_config}" ]; then
    echo "43-xform: xray config is missing: ${xray_config}" >&2
    return 1
  fi
  if ! getfacl -cp "${xray_config}" | grep -qx 'user:xform:r--'; then
    setfacl -m u:xform:r-- "${xray_config}"
    log "granted xform read access to ${xray_config}"
  fi
  if ! getfacl -cp "${xray_config_dir}" | grep -qx 'user:xform:rwx'; then
    setfacl -m u:xform:rwx "${xray_config_dir}"
    log "granted xform roster write access to ${xray_config_dir}"
  fi
  # Roster writes replace config.json with a new file. Preserve read access for
  # the unprivileged xray service even though the config is deliberately 0640.
  if ! getfacl -cp "${xray_config_dir}" | grep -qx "default:user:${xray_user}:r--"; then
    setfacl -m "d:u:${xray_user}:r--" "${xray_config_dir}"
    log "granted ${xray_user} inherited read access in ${xray_config_dir}"
  fi
  "${systemctl_cmd}" enable "${service}"
}

rollback_release() {
  local tag="$1"
  local had_previous="$2"
  local had_database="$3"
  local rollback_ok=1
  local quarantine_recorded=1

  if ! write_value "${tag}" "${rejected_version_file}"; then
    echo "43-xform: failed to record rejected release ${tag}" >&2
    quarantine_recorded=0
  fi

  if [ "${had_previous}" -eq 1 ]; then
    if ! atomic_copy "${install_path}.prev" "${install_path}"; then
      echo "43-xform: failed to restore the previous binary" >&2
      rollback_ok=0
    fi
    if ! restore_database "${had_database}"; then
      echo "43-xform: failed to restore the previous database" >&2
      rollback_ok=0
    fi
    if [ "${rollback_ok}" -eq 1 ] &&
      "${systemctl_cmd}" restart "${service}" && healthy; then
      if [ "${quarantine_recorded}" -eq 1 ]; then
        log "warning: rejected ${tag} and restored the previous release"
        return 0
      fi
      log "warning: restored the previous release but could not quarantine ${tag}"
      return 1
    fi
    echo "43-xform: previous ${service} could not be restored healthy" >&2
    return 1
  fi

  if ! restore_database "${had_database}"; then
    echo "43-xform: failed to restore pre-install database state" >&2
  fi
  rm -f "${install_path}"
  "${systemctl_cmd}" stop "${service}" || true
  return 1
}

install_latest() {
  local arch asset release_file tag checksum_url asset_url expected current_checksum
  local recorded_tag=""
  local recorded_checksum=""
  local had_previous=0
  local had_database=0

  if ! arch="$(architecture)"; then
    return 1
  fi
  asset="xform-linux-${arch}"

  if ! mkdir -p "$(dirname "${install_path}")" "${app_state_dir}" "${deployment_state_dir}"; then
    return 1
  fi
  temp_dir="$(mktemp -d "$(dirname "${install_path}")/.xform-update.XXXXXX")" || return 1
  release_file="${temp_dir}/release.json"

  if ! "${curl_cmd}" -fsSL "${release_api}" -o "${release_file}"; then
    echo "43-xform: unable to discover the latest release" >&2
    return 2
  fi
  if ! jq -e '.draft == false and .prerelease == false' "${release_file}" >/dev/null; then
    echo "43-xform: latest release metadata is not a stable release" >&2
    return 2
  fi
  if ! tag="$(jq -er '.tag_name' "${release_file}")"; then
    echo "43-xform: latest release has no tag" >&2
    return 2
  fi

  if [ -f "${rejected_version_file}" ] &&
    [ "$(cat "${rejected_version_file}")" = "${tag}" ]; then
    if [ ! -x "${install_path}" ]; then
      echo "43-xform: ${tag} is quarantined and no working version is installed" >&2
      return 1
    fi
    if ! ensure_running; then
      echo "43-xform: working version is unhealthy while ${tag} is quarantined" >&2
      return 1
    fi
    log "skipping quarantined ${tag}"
    return 0
  fi

  if ! checksum_url="$(jq -er '.assets[] | select(.name == "checksums.txt") | .browser_download_url' "${release_file}")" ||
    ! asset_url="$(jq -er --arg asset "${asset}" '.assets[] | select(.name == $asset) | .browser_download_url' "${release_file}")"; then
    echo "43-xform: ${tag} does not publish the required ${asset} assets" >&2
    return 2
  fi
  if ! "${curl_cmd}" -fsSL "${checksum_url}" -o "${temp_dir}/checksums.txt"; then
    echo "43-xform: unable to download checksums for ${tag}" >&2
    return 2
  fi
  expected="$(awk -v asset="${asset}" '$2 == asset {print $1}' "${temp_dir}/checksums.txt")"
  if [ -z "${expected}" ]; then
    echo "43-xform: ${asset} is missing from checksums.txt" >&2
    return 2
  fi

  if [ -s "${installed_release_file}" ]; then
    recorded_tag="$(awk 'NR == 1 {print $1}' "${installed_release_file}")"
    recorded_checksum="$(awk 'NR == 1 {print $2}' "${installed_release_file}")"
  fi
  if [ -x "${install_path}" ] && [ "${recorded_tag}" = "${tag}" ]; then
    current_checksum="$(sha256sum "${install_path}" | awk '{print $1}')"
    if [ -n "${recorded_checksum}" ]; then
      if [ "${current_checksum}" != "${recorded_checksum}" ]; then
        echo "43-xform: installed ${tag} does not match its recorded checksum" >&2
        return 1
      fi
    elif [ "${current_checksum}" = "${expected}" ]; then
      write_value "${tag} ${expected}" "${installed_release_file}" || return 1
    else
      echo "43-xform: installed ${tag} cannot be verified" >&2
      return 1
    fi
    if ! ensure_running; then
      echo "43-xform: installed ${tag} is not healthy" >&2
      return 1
    fi
    log "${tag} already installed"
    return 0
  fi

  if ! "${curl_cmd}" -fsSL "${asset_url}" -o "${temp_dir}/xform"; then
    echo "43-xform: unable to download ${asset} for ${tag}" >&2
    return 2
  fi
  if ! echo "${expected}  ${temp_dir}/xform" | sha256sum -c - >/dev/null; then
    echo "43-xform: checksum verification failed for ${asset}@${tag}" >&2
    return 2
  fi
  chmod 0755 "${temp_dir}/xform" || return 1

  if [ -x "${install_path}" ]; then
    had_previous=1
    if ! atomic_copy "${install_path}" "${install_path}.prev"; then
      echo "43-xform: failed to preserve the previous binary" >&2
      return 1
    fi
    if ! "${systemctl_cmd}" stop "${service}"; then
      "${systemctl_cmd}" start "${service}" || true
      echo "43-xform: failed to stop ${service} for update" >&2
      return 1
    fi
  fi

  if [ -f "${db_path}" ]; then
    had_database=1
    if ! atomic_copy "${db_path}" "${db_backup_path}"; then
      if [ "${had_previous}" -eq 1 ]; then
        "${systemctl_cmd}" start "${service}" || true
      fi
      echo "43-xform: failed to preserve xform state" >&2
      return 1
    fi
  else
    rm -f "${db_backup_path}"
  fi

  if ! mv -f "${temp_dir}/xform" "${install_path}"; then
    if [ "${had_previous}" -eq 1 ]; then
      "${systemctl_cmd}" start "${service}" || true
    fi
    echo "43-xform: failed to promote ${tag}" >&2
    return 1
  fi

  if ! "${systemctl_cmd}" restart "${service}" || ! healthy; then
    echo "43-xform: ${service} failed after installing ${tag}" >&2
    if rollback_release "${tag}" "${had_previous}" "${had_database}"; then
      return 0
    fi
    return 1
  fi

  write_value "${tag} ${expected}" "${installed_release_file}" || return 1
  rm -f "${rejected_version_file}"
  log "installed ${tag} (${asset})"
}

if [ "${lock_enabled}" = 1 ]; then
  exec 9>"${XFORM_LOCK_FILE:-/var/lock/xform-update.lock}"
  flock -n 9 || exit 0
fi

if [ "${host_setup}" = 1 ]; then
  setup_host
fi

status=0
install_latest || status=$?
if [ "${status}" -eq 2 ] && [ -x "${install_path}" ] &&
  [ -s "${installed_release_file}" ] &&
  [ "$(sha256sum "${install_path}" | awk '{print $1}')" = "$(awk 'NR == 1 {print $2}' "${installed_release_file}")" ]; then
  log "warning: release check failed; retaining the installed version"
  if ! ensure_running; then
    echo "43-xform: retained ${service} is not healthy" >&2
    exit 1
  fi
  record_active_service || exit 1
  exit 0
fi
if [ "${status}" -eq 0 ]; then
  record_active_service || exit 1
fi
exit "${status}"
