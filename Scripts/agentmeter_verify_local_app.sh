#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

if [[ -z "${APP_PATH}" ]]; then
  fail "Usage: $(basename "$0") /path/to/AgentMeter.app"
fi
if [[ ! -d "${APP_PATH}" ]]; then
  fail "App bundle not found: ${APP_PATH}"
fi
if [[ "$(basename "${APP_PATH}")" != *.app ]]; then
  fail "Expected an .app bundle path: ${APP_PATH}"
fi

CONTENTS="${APP_PATH}/Contents"
PLIST="${CONTENTS}/Info.plist"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
FRAMEWORKS="${CONTENTS}/Frameworks"

[[ -f "${PLIST}" ]] || fail "Missing Info.plist at ${PLIST}"
[[ -d "${MACOS}" ]] || fail "Missing MacOS directory at ${MACOS}"
[[ -d "${RESOURCES}" ]] || fail "Missing Resources directory at ${RESOURCES}"
[[ -d "${FRAMEWORKS}" ]] || fail "Missing Frameworks directory at ${FRAMEWORKS}"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "${PLIST}" 2>/dev/null
}

expect_plist() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(plist_value "${key}")" || fail "Missing Info.plist key: ${key}"
  [[ "${actual}" == "${expected}" ]] || fail "Info.plist ${key} expected '${expected}', got '${actual}'"
}

expect_missing_plist() {
  local key="$1"
  if plist_value "${key}" >/dev/null; then
    fail "Info.plist must not contain upstream key: ${key}"
  fi
}

expect_file() {
  local path="$1"
  [[ -f "${path}" ]] || fail "Missing file: ${path}"
}

expect_dir() {
  local path="$1"
  [[ -d "${path}" ]] || fail "Missing directory: ${path}"
}

expect_plist CFBundleName AgentMeter
expect_plist CFBundleDisplayName AgentMeter
expect_plist CFBundleIdentifier com.zain.agentmeter.menu
expect_plist CFBundleExecutable AgentMeter
expect_plist CFBundlePackageType APPL
expect_plist AgentMeterAppGroupIdentifier group.com.zain.agentmeter
expect_plist AgentMeterLocalBuild true
expect_plist NSLocalNetworkUsageDescription "AgentMeter shares your sanitized AI usage snapshot with your paired iPhone and iPad on your local network."
expect_missing_plist CodexBuildTimestamp
expect_missing_plist CodexBarTeamID

bonjour_service="$(/usr/libexec/PlistBuddy -c "Print :NSBonjourServices:0" "${PLIST}" 2>/dev/null || true)"
[[ "${bonjour_service}" == "_agentmeter._tcp" ]] || fail "Info.plist NSBonjourServices must include _agentmeter._tcp"

expect_file "${MACOS}/AgentMeter"
[[ -x "${MACOS}/AgentMeter" ]] || fail "AgentMeter executable is not executable: ${MACOS}/AgentMeter"
[[ ! -e "${MACOS}/CodexBar" ]] || fail "Packaged MacOS directory must not contain CodexBar executable"
[[ ! -e "${MACOS}/Sparkle.framework" ]] || fail "Packaged MacOS directory must not contain Sparkle.framework"
expect_dir "${FRAMEWORKS}/Sparkle.framework"

for asset in \
  Icon-classic.icns \
  AgentMeterMascot-claude-creature.svg \
  AgentMeterMenuBarIcon.svg \
  ProviderIcon-claude.svg \
  ProviderIcon-codex.svg \
  ProviderIcon-codex-dark.svg \
  ProviderWordmark-claude.svg \
  ProviderWordmark-claude-dark.svg \
  ProviderWordmark-codex.svg \
  ProviderWordmark-codex-dark.svg
do
  expect_file "${RESOURCES}/${asset}"
done

expect_dir "${RESOURCES}/KeyboardShortcuts_KeyboardShortcuts.bundle"

if /usr/bin/xattr -lr "${APP_PATH}" 2>/dev/null | /usr/bin/grep -E 'com\.apple\.(quarantine|metadata:kMDItemWhereFroms|metadata:kMDItemDownloadedDate)' >/dev/null; then
  fail "App bundle contains quarantine/download extended attributes; package must scrub xattrs before signing"
fi

group_id="$(plist_value AgentMeterAppGroupIdentifier)"
if [[ "${group_id}" != group.* ]]; then
  fail "AgentMeterAppGroupIdentifier must use iOS-style group prefix, got '${group_id}'"
fi
if [[ "${group_id}" == *com.steipete.codexbar* ]]; then
  fail "AgentMeterAppGroupIdentifier must not point at upstream CodexBar group"
fi

if [[ "${AGENTMETER_SKIP_CODESIGN_VERIFY:-0}" != "1" ]]; then
  if ! codesign_output="$(/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}" 2>&1)"; then
    echo "${codesign_output}" >&2
    fail "codesign strict verification failed for ${APP_PATH}"
  fi

  app_team="$(/usr/bin/codesign -dv "${APP_PATH}" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/ { print $2; exit }')"
  sparkle_team="$(/usr/bin/codesign -dv "${FRAMEWORKS}/Sparkle.framework" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/ { print $2; exit }')"
  if [[ "${app_team}" != "not set" && "${sparkle_team}" != "${app_team}" ]]; then
    fail "Sparkle.framework TeamIdentifier '${sparkle_team}' must match app TeamIdentifier '${app_team}'"
  fi
fi

echo "AgentMeter local app verification passed: ${APP_PATH}"
