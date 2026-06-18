#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIGURATION="${AGENTMETER_BUILD_CONFIGURATION:-release}"
BUILD_DIR="${ROOT_DIR}/.build/${BUILD_CONFIGURATION}"
ARTIFACT_DIR="${ROOT_DIR}/.agentmeter-artifacts"
VERSION_FILE="${ROOT_DIR}/version.env"

source "${ROOT_DIR}/Scripts/sparkle_signing_paths.sh"

if [[ ! -f "${VERSION_FILE}" ]]; then
  echo "ERROR: Missing ${VERSION_FILE}" >&2
  exit 1
fi

source "${VERSION_FILE}"

binary="${BUILD_DIR}/AgentMeter"
sparkle="${BUILD_DIR}/Sparkle.framework"
resources="${ROOT_DIR}/Sources/CodexBar/Resources"

detect_codesigning_identity() {
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  awk -F '"' '/Apple Development:/ { print $2; exit }' <<<"${identities}"
}

if [[ ! -x "${binary}" ]]; then
  echo "ERROR: ${BUILD_CONFIGURATION} binary missing at ${binary}. Run: swift build -c ${BUILD_CONFIGURATION} --product AgentMeter" >&2
  exit 1
fi
if [[ ! -d "${sparkle}" ]]; then
  echo "ERROR: Sparkle.framework missing at ${sparkle}. Run the ${BUILD_CONFIGURATION} build first." >&2
  exit 1
fi
if [[ ! -d "${resources}" ]]; then
  echo "ERROR: resources directory missing at ${resources}" >&2
  exit 1
fi

mkdir -p "${ARTIFACT_DIR}"
stamp="$(date -u +"%Y%m%d-%H%M%SZ")"
app="${ARTIFACT_DIR}/AgentMeter-${BUILD_CONFIGURATION}-${stamp}.app"
if [[ -e "${app}" ]]; then
  echo "ERROR: Refusing to overwrite existing artifact ${app}" >&2
  exit 1
fi

contents="${app}/Contents"
macos="${contents}/MacOS"
app_resources="${contents}/Resources"
frameworks="${contents}/Frameworks"
mkdir -p "${macos}" "${app_resources}" "${frameworks}"

cp "${binary}" "${macos}/AgentMeter"
chmod +x "${macos}/AgentMeter"
cp -R "${sparkle}" "${frameworks}/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${macos}/AgentMeter"
cp -R "${resources}/." "${app_resources}/"

for bundle in \
  "${BUILD_DIR}/AgentMeter_AgentMeter.bundle" \
  "${BUILD_DIR}/KeyboardShortcuts_KeyboardShortcuts.bundle" \
  "${BUILD_DIR}/Vortex_Vortex.bundle" \
  "${BUILD_DIR}/swift-crypto_Crypto.bundle"
do
  if [[ -d "${bundle}" ]]; then
    cp -R "${bundle}" "${app_resources}/"
  fi
done

if ! /bin/chmod -R u+rwX "${app}"; then
  echo "ERROR: Failed to normalize permissions in ${app}" >&2
  exit 1
fi
if ! /usr/bin/xattr -cr "${app}"; then
  echo "ERROR: Failed to clear extended attributes from ${app}" >&2
  exit 1
fi

build_timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
git_commit="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

cat > "${contents}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AgentMeter</string>
    <key>CFBundleDisplayName</key><string>AgentMeter</string>
    <key>CFBundleIdentifier</key><string>com.zain.agentmeter.menu</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>AgentMeter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION:-0.1.0-dev}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER:-1}</string>
    <key>AgentMeterAppGroupIdentifier</key><string>group.com.zain.agentmeter</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>Icon-classic</string>
    <key>NSLocalNetworkUsageDescription</key><string>AgentMeter shares your sanitized AI usage snapshot with your paired iPhone and iPad on your local network.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_agentmeter._tcp</string>
    </array>
    <key>AgentMeterBuildTimestamp</key><string>${build_timestamp}</string>
    <key>AgentMeterGitCommit</key><string>${git_commit}</string>
    <key>AgentMeterLocalBuild</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "${contents}/PkgInfo"

if [[ ! -f "${app_resources}/Icon-classic.icns" ]]; then
  echo "ERROR: Missing Icon-classic.icns in ${app_resources}" >&2
  exit 1
fi
for asset in \
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
  if [[ ! -f "${app_resources}/${asset}" ]]; then
    echo "ERROR: Missing ${asset} in ${app_resources}" >&2
    exit 1
  fi
done
if [[ ! -d "${app_resources}/KeyboardShortcuts_KeyboardShortcuts.bundle" ]]; then
  echo "ERROR: Missing KeyboardShortcuts resource bundle in ${app_resources}" >&2
  exit 1
fi

codesign_identity="${AGENTMETER_CODESIGN_IDENTITY:-}"
if [[ -z "${codesign_identity}" ]]; then
  codesign_identity="$(detect_codesigning_identity)"
fi
if [[ -z "${codesign_identity}" ]]; then
  echo "WARNING: No Apple Development signing identity found; using ad-hoc local signing." >&2
  codesign_identity="-"
fi
codesign_args=(--force --timestamp=none --options runtime --sign "${codesign_identity}")

sparkle_targets="$(codexbar_sparkle_signing_targets "${frameworks}/Sparkle.framework")"
while IFS= read -r sparkle_target; do
  if [[ -n "${sparkle_target}" ]]; then
    /usr/bin/codesign "${codesign_args[@]}" "${sparkle_target}"
  fi
done <<<"${sparkle_targets}"

if ! codesign_output="$(/usr/bin/codesign "${codesign_args[@]}" "${app}" 2>&1)"
then
  echo "${codesign_output}" >&2
  echo "ERROR: Failed to sign ${app}" >&2
  exit 1
fi

"${ROOT_DIR}/Scripts/agentmeter_verify_local_app.sh" "${app}" >/dev/null

echo "${app}"
