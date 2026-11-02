#!/usr/bin/env bash
# Runs the end-to-end scouting test on the booted iOS simulator and captures a real simulator
# screenshot (build/screenshots/<name>.png) whenever the test prints SCREENSHOT:<name>.
# The simulator is placed ~180 m from the test field's first target and granted location access.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE=${DEVICE:-booted}
LAT=${LAT:-52.5402}
LON=${LON:-5.6000}
BUNDLE=com.agripulse.agripulseScout
LOG=build/drive.log
mkdir -p build/screenshots
rm -f build/screenshots/*.png

xcrun simctl location "$DEVICE" set "$LAT,$LON"

# `flutter drive` reinstalls the app, which resets permissions, and the iOS prompt would block the test.
# Grant location as soon as the fresh install appears, before the app asks.
xcrun simctl uninstall "$DEVICE" "$BUNDLE" 2>/dev/null || true
(
  until xcrun simctl get_app_container "$DEVICE" "$BUNDLE" >/dev/null 2>&1; do sleep 0.2; done
  xcrun simctl privacy "$DEVICE" grant location "$BUNDLE"
) &
GRANTER=$!

: > "$LOG"
tail -n0 -F "$LOG" 2>/dev/null | while IFS= read -r line; do
  if [[ "$line" == *SCREENSHOT:* ]]; then
    name=${line##*SCREENSHOT:}
    xcrun simctl io "$DEVICE" screenshot "build/screenshots/${name//[^A-Za-z0-9_-]/}.png" >/dev/null 2>&1
  fi
done &
WATCHER=$!
trap 'kill $WATCHER $GRANTER 2>/dev/null || true' EXIT

flutter drive --driver test_driver/integration_test.dart --target integration_test/scout_flow_test.dart \
  ${FLUTTER_DEVICE:+-d "$FLUTTER_DEVICE"} "$@" >> "$LOG" 2>&1
