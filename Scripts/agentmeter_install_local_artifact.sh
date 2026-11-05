#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"
latest_app="$(find "${ROOT_DIR}/.agentmeter-artifacts" -maxdepth 1 -type d -name 'AgentMeter-release-*.app' -print | sort | tail -1)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ -z "${APP}" ]]; then
  APP="${latest_app}"
fi

if [[ -z "${APP}" || ! -d "${APP}" ]]; then
  echo "ERROR: AgentMeter app artifact not found. Pass the .app path explicitly." >&2
  exit 1
fi
APP="$(cd "$(dirname "${APP}")" && pwd)/$(basename "${APP}")"

if [[ -n "${latest_app}" && "${APP}" != "${latest_app}" && "${AGENTMETER_ALLOW_STALE_ARTIFACT:-0}" != "1" ]]; then
  echo "ERROR: ${APP} is not the newest local AgentMeter artifact." >&2
  echo "Newest artifact: ${latest_app}" >&2
  echo "Set AGENTMETER_ALLOW_STALE_ARTIFACT=1 only if you intentionally want a rollback." >&2
  exit 1
fi

if [[ ! -x "${APP}/Contents/MacOS/AgentMeter" ]]; then
  echo "ERROR: ${APP} is missing Contents/MacOS/AgentMeter" >&2
  exit 1
fi

build_timestamp() {
  local app_path="$1"
  /usr/bin/plutil -extract AgentMeterBuildTimestamp raw "${app_path}/Contents/Info.plist" 2>/dev/null || true
}

trash_path() {
  local path="$1"
  [[ -e "${path}" ]] || return 0
  local trash_dir="${HOME}/.Trash"
  local base
  local target
  base="$(basename "${path}")"
  target="${trash_dir}/${base}"
  if [[ -e "${target}" ]]; then
    target="${trash_dir}/${base}.$(date -u +"%Y%m%d-%H%M%SZ").$$"
  fi
  if mkdir -p "${trash_dir}" && /bin/mv "${path}" "${target}" 2>/dev/null; then
    return 0
  fi
  /usr/bin/osascript - "${path}" <<'APPLESCRIPT'
on run argv
  set targetPath to item 1 of argv
  set targetItem to POSIX file targetPath as alias
  tell application "Finder" to delete targetItem
end run
APPLESCRIPT
}

archive_installed_app() {
  local path="$1"
  [[ -e "${path}" ]] || return 0

  local stamp
  local archive_dir
  local archived_path
  local bundle_name
  local quarantined_path
  stamp="$(date -u +"%Y%m%d-%H%M%SZ")"
  archive_dir="${ROOT_DIR}/.agentmeter-artifacts/archived-installed-app-bundles/${stamp}"
  bundle_name="$(basename "${path}")"
  archived_path="${archive_dir}/${bundle_name%.app}-bundle.zip"
  if [[ -e "${archived_path}" ]]; then
    archived_path="${archive_dir}/${bundle_name%.app}-bundle.${stamp}.$$.zip"
  fi
  quarantined_path="${archive_dir}/${bundle_name%.app}-bundle.staging.$$"

  mkdir -p "${archive_dir}"
  /bin/chmod 700 "${archive_dir}"
  "${LSREGISTER}" -u "${path}" >/dev/null 2>&1 || true
  /bin/mv "${path}" "${quarantined_path}"
  if ! confirm_no_foreign_agentmeter_processes; then
    /bin/mv "${quarantined_path}" "${path}"
    "${LSREGISTER}" -f "${path}" >/dev/null 2>&1 || true
    return 7
  fi
  if ! /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${quarantined_path}" "${archived_path}"; then
    /bin/mv "${quarantined_path}" "${path}"
    "${LSREGISTER}" -f "${path}" >/dev/null 2>&1 || true
    return 8
  fi
  if ! confirm_no_foreign_agentmeter_processes; then
    /bin/rm "${archived_path}"
    /bin/mv "${quarantined_path}" "${path}"
    "${LSREGISTER}" -f "${path}" >/dev/null 2>&1 || true
    return 7
  fi
  /bin/rm -R "${quarantined_path}"
  printf 'original_path\tarchived_path\n%s\t%s\n' \
    "${path}" \
    "${archived_path}" > "${archive_dir}/manifest.tsv"
  echo "Archived previous install as ${archived_path}"
}

agentmeter_macos_pid_records() {
  local pid
  local pgrep_output
  local pgrep_status
  local process_uid
  local executable
  local process_record
  pgrep_output="$(/usr/bin/pgrep -x AgentMeter 2>/dev/null)" || pgrep_status=$?
  pgrep_status="${pgrep_status:-0}"
  if [[ "${pgrep_status}" -eq 1 ]]; then
    return 0
  elif [[ "${pgrep_status}" -ne 0 ]]; then
    echo "ERROR: Could not enumerate AgentMeter processes safely." >&2
    return 70
  fi
  for pid in ${pgrep_output}; do
    if ! process_record="$(/bin/ps -p "${pid}" -o uid= -o comm= 2>/dev/null)"; then
      echo "ERROR: Could not inspect AgentMeter PID ${pid} safely." >&2
      return 70
    fi
    read -r process_uid executable <<<"${process_record}"
    if [[ -z "${process_uid}" || -z "${executable}" ]]; then
      echo "ERROR: AgentMeter PID ${pid} returned incomplete process metadata." >&2
      return 70
    fi
    case "${executable}" in
      /Applications/AgentMeter.app/Contents/MacOS/AgentMeter|\
      "${ROOT_DIR}"/.agentmeter-artifacts/*/Contents/MacOS/AgentMeter|\
      "${ROOT_DIR}"/.agentmeter-artifacts/probes/*/Contents/MacOS/AgentMeter)
        printf '%s\t%s\n' "${pid}" "${process_uid}"
        ;;
    esac
  done
}

agentmeter_macos_pids() {
  local current_uid
  local pid
  local process_uid
  local records
  current_uid="$(id -u)"
  if ! records="$(agentmeter_macos_pid_records)"; then
    return 70
  fi
  while IFS=$'\t' read -r pid process_uid; do
    [[ -n "${pid}" && "${process_uid}" == "${current_uid}" ]] && echo "${pid}"
  done <<<"${records}"
  return 0
}

agentmeter_foreign_macos_pids() {
  local current_uid
  local pid
  local process_uid
  local records
  current_uid="$(id -u)"
  if ! records="$(agentmeter_macos_pid_records)"; then
    return 70
  fi
  while IFS=$'\t' read -r pid process_uid; do
    [[ -n "${pid}" && "${process_uid}" != "${current_uid}" ]] && echo "${pid}"
  done <<<"${records}"
  return 0
}

refuse_foreign_agentmeter_processes() {
  local foreign_pids
  local raw_foreign_pids
  if ! raw_foreign_pids="$(agentmeter_foreign_macos_pids)"; then
    echo "ERROR: Process inspection failed; refusing to replace the shared app bundle." >&2
    return 70
  fi
  foreign_pids="$(/usr/bin/xargs <<<"${raw_foreign_pids}")"
  if [[ -n "${foreign_pids}" ]]; then
    echo "ERROR: Another macOS user is currently running AgentMeter." >&2
    echo "Foreign AgentMeter PID(s): ${foreign_pids}" >&2
    echo "Quit AgentMeter in the other user session before replacing the shared app bundle." >&2
    return 7
  fi
}

confirm_no_foreign_agentmeter_processes() {
  local attempt
  for attempt in 1 2 3 4 5; do
    refuse_foreign_agentmeter_processes || return $?
    if [[ "${attempt}" -lt 5 ]]; then
      /bin/sleep 0.2
    fi
  done
}

agentmeter_launchservices_running() {
  /bin/launchctl print "gui/$(id -u)" 2>/dev/null \
    | /usr/bin/grep -Eq 'application\.com\.zain\.agentmeter\.menu\.|application\.com\.zain\.agentmeter\.mac\.|application\.com\.zain\.agentmeter\.[0-9]'
}

agentmeter_running() {
  local mac_pids
  if ! mac_pids="$(agentmeter_macos_pids)"; then
    return 70
  fi
  if [[ -n "${mac_pids}" ]]; then
    return 0
  fi
  agentmeter_launchservices_running
}

agentmeter_pids() {
  {
    /bin/launchctl print "gui/$(id -u)" 2>/dev/null \
    | /usr/bin/awk '
        /application\.com\.zain\.agentmeter\.menu\./ ||
        /application\.com\.zain\.agentmeter\.mac\./ ||
        /application\.com\.zain\.agentmeter\.[0-9]/ {
          if ($1 ~ /^[0-9]+$/ && $1 != "0") print $1
        }
      '
    agentmeter_macos_pids
  } | /usr/bin/sort -u
}

backup_defaults_domain() {
  local domain="$1"
  local backup_dir="${ROOT_DIR}/.agentmeter-artifacts/menu-bar-defaults-backups"
  local stamp
  stamp="$(date -u +"%Y%m%d-%H%M%SZ")"
  mkdir -p "${backup_dir}"
  /usr/bin/defaults export "${domain}" "${backup_dir}/${domain}-${stamp}.plist" >/dev/null 2>&1 || true
}

delete_defaults_key() {
  local domain="$1"
  local key="$2"
  /usr/bin/defaults delete "${domain}" "${key}" >/dev/null 2>&1 || true
}

reset_agentmeter_menu_bar_defaults() {
  echo "Backing up and clearing stale AgentMeter menu-bar defaults from previous local builds..."
  for domain in \
    com.apple.controlcenter \
    com.zain.agentmeter.menu \
    com.zain.agentmeter.mac \
    com.zain.agentmeter.local \
    com.zain.agentmeter.dev
  do
    backup_defaults_domain "${domain}"
  done

  local prefixes=(
    "NSStatusItem Preferred Position "
    "NSStatusItem Visible "
    "NSStatusItem VisibleCC "
  )
  local stale_names=(
    "agentmeter-merged"
    "agentmeter-codex"
    "agentmeter-claude"
    "agentmeter-gemini"
    "agentmeter-v4-merged"
    "agentmeter-v4-codex"
    "agentmeter-v4-claude"
    "agentmeter-v4-gemini"
    "com.zain.agentmeter.local"
    "com.zain.agentmeter.local.codex"
    "com.zain.agentmeter.local.claude"
    "com.zain.agentmeter.local.gemini"
    "com.zain.agentmeter.menu"
    "com.zain.agentmeter.menu.codex"
    "com.zain.agentmeter.menu.claude"
    "com.zain.agentmeter.menu.gemini"
    "com.zain.agentmeter.mac"
    "com.zain.agentmeter.mac.codex"
    "com.zain.agentmeter.mac.claude"
    "com.zain.agentmeter.mac.gemini"
    "com.zain.agentmeter.statusitem.v2-merged"
    "com.zain.agentmeter.statusitem.v2-codex"
    "com.zain.agentmeter.statusitem.v2-claude"
    "com.zain.agentmeter.statusitem.v2-gemini"
    "com.zain.agentmeter.statusitem.v3-merged"
    "com.zain.agentmeter.statusitem.v3-codex"
    "com.zain.agentmeter.statusitem.v3-claude"
    "com.zain.agentmeter.statusitem.v3-gemini"
    "com.zain.agentmeter.statusitem.v5-merged"
    "com.zain.agentmeter.statusitem.v5-codex"
    "com.zain.agentmeter.statusitem.v5-claude"
    "com.zain.agentmeter.statusitem.v5-gemini"
  )

  local domain
  local prefix
  local name
  for domain in \
    com.apple.controlcenter \
    com.zain.agentmeter.menu \
    com.zain.agentmeter.mac \
    com.zain.agentmeter.local \
    com.zain.agentmeter.dev
  do
    for prefix in "${prefixes[@]}"; do
      for name in "${stale_names[@]}"; do
        delete_defaults_key "${domain}" "${prefix}${name}"
      done
    done
  done
}

refuse_foreign_agentmeter_processes

echo "Quitting AgentMeter if it is running..."
/usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
try
  tell application id "com.zain.agentmeter.menu" to quit
end try
try
  tell application id "com.zain.agentmeter.mac" to quit
end try
try
  tell application id "com.zain.agentmeter" to quit
end try
APPLESCRIPT

for _ in 1 2 3 4 5; do
  pids="$(agentmeter_pids | /usr/bin/xargs)"
  if [[ -z "${pids}" ]]; then
    break
  fi
  /bin/sleep 1
done

pids="$(agentmeter_pids | /usr/bin/xargs)"
if [[ -n "${pids}" && "${AGENTMETER_NO_FORCE_QUIT:-0}" != "1" ]]; then
  echo "AgentMeter did not quit cleanly; terminating AgentMeter PID(s): ${pids}"
  for pid in ${pids}; do
    /bin/kill -TERM "${pid}" 2>/dev/null || true
  done
  for _ in 1 2 3 4 5; do
    pids="$(agentmeter_pids | /usr/bin/xargs)"
    if [[ -z "${pids}" ]]; then
      break
    fi
    /bin/sleep 1
  done
fi

pids="$(agentmeter_pids | /usr/bin/xargs)"
if [[ -n "${pids}" ]]; then
  echo "ERROR: AgentMeter is still running, so the installer will not replace the app under it." >&2
  echo "Remaining AgentMeter PID(s): ${pids}" >&2
  echo "Only AgentMeter was targeted. DashPad and provider caches were not touched." >&2
  echo "If needed, quit AgentMeter from Activity Monitor, then rerun this script." >&2
  exit 2
fi

if [[ "${AGENTMETER_RESET_MENU_BAR_STATE:-0}" == "1" ]]; then
  reset_agentmeter_menu_bar_defaults
else
  echo "Leaving macOS Control Center menu-bar defaults untouched."
fi

artifact_timestamp="$(build_timestamp "${APP}")"
if [[ -n "${artifact_timestamp}" ]]; then
  echo "Artifact build timestamp: ${artifact_timestamp}"
fi

echo "Cleaning old AgentMeter backup folders from /Applications..."
for backup in /Applications/AgentMeter.app.backup.*; do
  [[ -e "${backup}" ]] || continue
  trash_path "${backup}"
done

TMP_APP="/Applications/.AgentMeter.app.install.$$"
cleanup_tmp() {
  if [[ -e "${TMP_APP}" ]]; then
    trash_path "${TMP_APP}" || true
  fi
}
trap cleanup_tmp EXIT

echo "Copying ${APP}..."
/usr/bin/ditto "${APP}" "${TMP_APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${TMP_APP}" >/dev/null
refuse_foreign_agentmeter_processes

if [[ -e /Applications/AgentMeter.app ]]; then
  archive_installed_app /Applications/AgentMeter.app
fi

/bin/mv "${TMP_APP}" /Applications/AgentMeter.app
"${LSREGISTER}" -f /Applications/AgentMeter.app >/dev/null 2>&1 || true
trap - EXIT

if [[ "${AGENTMETER_ARCHIVE_LOCAL_APP_ARTIFACTS:-1}" == "1" ]]; then
  echo "Archiving local AgentMeter .app artifacts so macOS does not rediscover stale menu-bar apps..."
  if ! /bin/bash "${ROOT_DIR}/Scripts/agentmeter_cleanup_stale_local_apps.sh" --apply >/dev/null; then
    echo "WARNING: Failed to archive local AgentMeter app artifacts. Run Scripts/agentmeter_cleanup_stale_local_apps.sh --apply manually." >&2
  fi
fi

echo "Launching AgentMeter with a clean environment..."
launch_started="$(date +%s)"
env -i \
  HOME="${HOME}" \
  USER="${USER:-$(id -un)}" \
  LOGNAME="${LOGNAME:-$(id -un)}" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  TMPDIR="${TMPDIR:-/tmp}" \
  /usr/bin/open /Applications/AgentMeter.app

/bin/sleep 3
echo "Installed and launched /Applications/AgentMeter.app"
mac_pids="$(agentmeter_macos_pids | /usr/bin/xargs)"
mac_pid_count="$(/usr/bin/wc -w <<<"${mac_pids}" | /usr/bin/tr -d ' ')"
if [[ "${mac_pid_count}" -gt 1 ]]; then
  echo "ERROR: Multiple Mac AgentMeter processes are running after launch: ${mac_pids}" >&2
  exit 6
fi
installed_timestamp="$(build_timestamp /Applications/AgentMeter.app)"
if [[ -n "${installed_timestamp}" ]]; then
  echo "Installed build timestamp: ${installed_timestamp}"
fi
echo "Diagnostics: ${HOME}/Library/Application Support/AgentMeter/status-item-diagnostics.json"

diagnostics="${HOME}/Library/Application Support/AgentMeter/status-item-diagnostics.json"
diagnostics_fresh=0
for _ in 1 2 3 4 5; do
  if [[ -f "${diagnostics}" ]]; then
    diagnostics_mtime="$(/usr/bin/stat -f %m "${diagnostics}" 2>/dev/null || echo 0)"
    if [[ "${diagnostics_mtime}" -ge "${launch_started}" ]]; then
      diagnostics_fresh=1
      break
    fi
  fi
  /bin/sleep 1
done

if [[ -f "${diagnostics}" ]]; then
  if [[ "${diagnostics_fresh}" != "1" ]]; then
    echo "ERROR: AgentMeter did not write fresh diagnostics after launch." >&2
    echo "Open /Applications/AgentMeter.app manually, then inspect: ${diagnostics}" >&2
    exit 3
  fi
  if ! /usr/bin/grep -q '"schemaVersion" : 3' "${diagnostics}"; then
    echo "ERROR: AgentMeter diagnostics are not schemaVersion 3; a stale app is still running." >&2
    exit 4
  fi
  if ! /usr/bin/grep -q '"bundleIdentifier" : "com.zain.agentmeter.menu"' "${diagnostics}"; then
    echo "ERROR: AgentMeter diagnostics do not show the AgentMeter bundle identifier." >&2
    exit 5
  fi
  diagnostics_settled=0
  if [[ -x /usr/bin/jq ]]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if /usr/bin/jq -e '
        .items[0].isVisible == true
        and .items[0].isBlocked == false
        and .items[0].isInMenuExtraRegion == true
      ' "${diagnostics}" >/dev/null 2>&1; then
        diagnostics_settled=1
        break
      fi
      /bin/sleep 1
    done
    if [[ "${diagnostics_settled}" != "1" ]]; then
      echo "WARNING: AgentMeter diagnostics did not settle into the menu-extra region before timeout." >&2
    fi
  fi
  if ! /usr/bin/grep -q '"autosaveName" : "com.zain.agentmeter.menu"' "${diagnostics}"; then
    echo "WARNING: AgentMeter diagnostics do not show the current AgentMeter autosave name yet." >&2
  fi
  if ! /usr/bin/grep -q '"imageIsTemplate" : true' "${diagnostics}"; then
    echo "WARNING: AgentMeter diagnostics do not show a template menu-bar image yet." >&2
  fi
  if /usr/bin/grep -q '"launchedFromCodexShell" : true' "${diagnostics}"; then
    echo "WARNING: AgentMeter diagnostics show a Codex launch marker. This is diagnostic only." >&2
  fi
  if command -v jq >/dev/null 2>&1; then
    echo "Menu-bar diagnostics summary:"
    /usr/bin/jq -r '
      "  bundleIdentifier: \(.bundleIdentifier)",
      "  generatedAt: \(.generatedAt)",
      "  autosaveName: \(.items[0].autosaveName // "missing")",
      "  isVisible: \(.items[0].isVisible)",
      "  isBlocked: \(.items[0].isBlocked)",
      "  isDisplaced: \(.items[0].isDisplaced)",
      "  isInMenuExtraRegion: \(.items[0].isInMenuExtraRegion)",
      "  windowX: \(.items[0].windowX)",
      "  imageIsTemplate: \(.items[0].imageIsTemplate)",
      "  imageSize: \(.items[0].imageWidth)x\(.items[0].imageHeight)",
      "  launchAtLogin: \(.launchAtLogin)",
      "  loginItemStatus: \(.loginItemStatus)"
    ' "${diagnostics}"
  fi
fi
