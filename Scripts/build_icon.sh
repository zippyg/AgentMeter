#!/usr/bin/env bash
set -euo pipefail

# Regenerates the macOS Icon.icns from the AgentMeter robot SVG as a rounded squircle.
# The iOS app-icon SVG is the single source of truth, so the Mac and iOS icons stay
# identical. Dependencies: Xcode command line tools (swift, sips, iconutil).
# Usage: Scripts/build_icon.sh [svg] [out.icns]

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="${1:-$ROOT_DIR/AgentMeteriOS/Shared/Assets.xcassets/AppIcon.appiconset/AgentMeterIconSource.svg}"
# The shipped Mac icon is the SwiftPM resource bundled as CFBundleIconFile=Icon-classic.
OUT_ICNS="${2:-$ROOT_DIR/Sources/CodexBar/Resources/Icon-classic.icns}"
RADIUS="${ICON_CORNER_RADIUS:-225}"

if [[ ! -f "$SVG" ]]; then
  echo "ERROR: icon source SVG not found: $SVG" >&2
  exit 1
fi

WORK="$(mktemp -d)"
MASTER="$WORK/icon_1024.png"
ICONSET="$WORK/AgentMeter.iconset"
mkdir -p "$ICONSET"

swift "$ROOT_DIR/Scripts/build_mac_icon.swift" "$SVG" "$MASTER" 1024 "$RADIUS"

for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz" "$MASTER" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  dbl=$((sz * 2))
  sips -z "$dbl" "$dbl" "$MASTER" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
echo "Wrote $OUT_ICNS from $SVG"
