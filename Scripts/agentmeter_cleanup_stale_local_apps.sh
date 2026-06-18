#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ROOT_DIR}/.agentmeter-artifacts"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
STAMP="$(date -u +"%Y%m%d-%H%M%SZ")"
ARCHIVE_ROOT="${ARTIFACT_DIR}/archived-app-bundles/${STAMP}"
APPLY=0
REBUILD_USER_DOMAIN=0

usage() {
  cat <<'USAGE'
Usage:
  Scripts/agentmeter_cleanup_stale_local_apps.sh [--apply] [--rebuild-user-domain]

Archives stale AgentMeter .app bundles from .agentmeter-artifacts so macOS cannot keep
discovering old timestamped apps as menu-bar/background items.

Default is dry-run. --apply unregisters each found bundle from LaunchServices and
moves it to .agentmeter-artifacts/archived-app-bundles/<timestamp>/<name>.app.archived.

This script never touches /Applications/AgentMeter.app, DashPad, Codex, provider
caches, Keychain, or generic Item-0 menu-bar preferences.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --rebuild-user-domain)
      REBUILD_USER_DOMAIN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "${ARTIFACT_DIR}" ]]; then
  echo "No .agentmeter-artifacts directory found at ${ARTIFACT_DIR}"
  exit 0
fi

apps=()
while IFS= read -r app; do
  apps+=("${app}")
done < <(
  find "${ARTIFACT_DIR}" \
    -maxdepth 1 \
    -type d \
    \( -name 'AgentMeter*.app' -o -name '*AgentMeter*.app' \) \
    -print | sort
)

if [[ "${#apps[@]}" -eq 0 ]]; then
  echo "No stale AgentMeter app bundles found in ${ARTIFACT_DIR}"
  exit 0
fi

plist_value() {
  local app="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "${app}/Contents/Info.plist" 2>/dev/null || true
}

codesign_identifier() {
  local app="$1"
  /usr/bin/codesign -dv "${app}" 2>&1 | /usr/bin/awk -F= '/^Identifier=/ { print $2; exit }' || true
}

echo "Found ${#apps[@]} stale AgentMeter app bundle(s) in ${ARTIFACT_DIR}:"
for app in "${apps[@]}"; do
  bundle_id="$(plist_value "${app}" CFBundleIdentifier)"
  display_name="$(plist_value "${app}" CFBundleDisplayName)"
  signing_id="$(codesign_identifier "${app}")"
  echo "  $(basename "${app}") bundle=${bundle_id:-unknown} display=${display_name:-unknown} codesign=${signing_id:-unknown}"
done

if [[ "${APPLY}" != "1" ]]; then
  echo "Dry-run only. Re-run with --apply to archive and unregister these bundles."
  exit 0
fi

mkdir -p "${ARCHIVE_ROOT}"
manifest="${ARCHIVE_ROOT}/manifest.tsv"
printf 'original_path\tarchived_path\tbundle_id\tdisplay_name\tcodesign_identifier\n' > "${manifest}"

for app in "${apps[@]}"; do
  base="$(basename "${app}")"
  dest="${ARCHIVE_ROOT}/${base}.archived"
  bundle_id="$(plist_value "${app}" CFBundleIdentifier)"
  display_name="$(plist_value "${app}" CFBundleDisplayName)"
  signing_id="$(codesign_identifier "${app}")"

  if [[ -e "${dest}" ]]; then
    dest="${ARCHIVE_ROOT}/${base}.archived.${STAMP}.$$"
  fi

  echo "Unregistering ${app}"
  "${LSREGISTER}" -u "${app}" >/dev/null 2>&1 || true

  echo "Archiving ${base} -> ${dest}"
  /bin/mv "${app}" "${dest}"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${app}" \
    "${dest}" \
    "${bundle_id}" \
    "${display_name}" \
    "${signing_id}" >> "${manifest}"
done

if [[ "${REBUILD_USER_DOMAIN}" == "1" ]]; then
  echo "Rebuilding user LaunchServices registration database..."
  "${LSREGISTER}" -kill -r -domain user >/dev/null 2>&1 || true
fi

echo "Archived stale app bundles under ${ARCHIVE_ROOT}"
echo "Manifest: ${manifest}"
