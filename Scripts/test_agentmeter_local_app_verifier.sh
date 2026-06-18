#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERIFIER="${ROOT}/Scripts/agentmeter_verify_local_app.sh"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agentmeter-local-app-verifier.XXXXXX")

make_fixture() {
  local app="$1"
  local contents="${app}/Contents"
  local macos="${contents}/MacOS"
  local resources="${contents}/Resources"
  local frameworks="${contents}/Frameworks"
  mkdir -p "${macos}" "${frameworks}/Sparkle.framework" "${resources}/KeyboardShortcuts_KeyboardShortcuts.bundle"
  touch "${macos}/AgentMeter"
  chmod +x "${macos}/AgentMeter"
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
    touch "${resources}/${asset}"
  done
  cat > "${contents}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AgentMeter</string>
    <key>CFBundleDisplayName</key><string>AgentMeter</string>
    <key>CFBundleIdentifier</key><string>com.zain.agentmeter.menu</string>
    <key>CFBundleExecutable</key><string>AgentMeter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>AgentMeterAppGroupIdentifier</key><string>group.com.zain.agentmeter</string>
    <key>NSLocalNetworkUsageDescription</key><string>AgentMeter shares your sanitized AI usage snapshot with your paired iPhone and iPad on your local network.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_agentmeter._tcp</string>
    </array>
    <key>AgentMeterLocalBuild</key><true/>
</dict>
</plist>
PLIST
  /bin/chmod -R u+rwX "${app}"
  /usr/bin/xattr -cr "${app}"
}

GOOD_APP="${TEMP_DIR}/AgentMeter.app"
make_fixture "${GOOD_APP}"
if "${VERIFIER}" "${GOOD_APP}" >"${TEMP_DIR}/unsigned.out" 2>"${TEMP_DIR}/unsigned.err"; then
  echo "ERROR: Verifier accepted an unsigned app by default." >&2
  exit 1
fi
grep -Fq "codesign strict verification failed" "${TEMP_DIR}/unsigned.err"
export AGENTMETER_SKIP_CODESIGN_VERIFY=1
"${VERIFIER}" "${GOOD_APP}" >/dev/null

BAD_ID_APP="${TEMP_DIR}/BadIdentifier.app"
make_fixture "${BAD_ID_APP}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.steipete.codexbar" "${BAD_ID_APP}/Contents/Info.plist"
if "${VERIFIER}" "${BAD_ID_APP}" >"${TEMP_DIR}/bad-id.out" 2>"${TEMP_DIR}/bad-id.err"; then
  echo "ERROR: Verifier accepted upstream bundle identifier." >&2
  exit 1
fi
grep -Fq "CFBundleIdentifier expected" "${TEMP_DIR}/bad-id.err"

BAD_GROUP_APP="${TEMP_DIR}/BadGroup.app"
make_fixture "${BAD_GROUP_APP}"
/usr/libexec/PlistBuddy -c "Set :AgentMeterAppGroupIdentifier TEAMID.com.zain.agentmeter" "${BAD_GROUP_APP}/Contents/Info.plist"
if "${VERIFIER}" "${BAD_GROUP_APP}" >"${TEMP_DIR}/bad-group.out" 2>"${TEMP_DIR}/bad-group.err"; then
  echo "ERROR: Verifier accepted Team-ID style app group." >&2
  exit 1
fi
grep -Fq "AgentMeterAppGroupIdentifier expected" "${TEMP_DIR}/bad-group.err"

BAD_KEY_APP="${TEMP_DIR}/BadKey.app"
make_fixture "${BAD_KEY_APP}"
/usr/libexec/PlistBuddy -c "Add :CodexBuildTimestamp string 2026-06-14T00:00:00Z" "${BAD_KEY_APP}/Contents/Info.plist"
if "${VERIFIER}" "${BAD_KEY_APP}" >"${TEMP_DIR}/bad-key.out" 2>"${TEMP_DIR}/bad-key.err"; then
  echo "ERROR: Verifier accepted upstream build key." >&2
  exit 1
fi
grep -Fq "must not contain upstream key" "${TEMP_DIR}/bad-key.err"

BAD_EXEC_APP="${TEMP_DIR}/BadExecutable.app"
make_fixture "${BAD_EXEC_APP}"
touch "${BAD_EXEC_APP}/Contents/MacOS/CodexBar"
if "${VERIFIER}" "${BAD_EXEC_APP}" >"${TEMP_DIR}/bad-exec.out" 2>"${TEMP_DIR}/bad-exec.err"; then
  echo "ERROR: Verifier accepted CodexBar executable." >&2
  exit 1
fi
grep -Fq "must not contain CodexBar executable" "${TEMP_DIR}/bad-exec.err"

echo "AgentMeter local app verifier tests passed."
