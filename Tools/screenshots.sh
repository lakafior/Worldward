#!/usr/bin/env bash
# Capture the raw App Store screenshot matrix.
#
# No XCUITest target is involved: the app's DEBUG screenshot harness
# (Worldward/ScreenshotSupport.swift) seeds an in-memory demo store and routes
# straight to a named screen, all from launch arguments — so plain `simctl` can
# drive the whole matrix headlessly.
#
#   ./Tools/screenshots.sh                 # full run (22 langs x 2 modes x 10 screens)
#   LANGS="en de" ./Tools/screenshots.sh   # subset while iterating
#
# Build + install first:
#   xcodebuild -project Worldward.xcodeproj -scheme Worldward \
#     -destination 'id=<UDID>' -configuration Debug build
#   xcrun simctl install <UDID> <path/to/Worldward.app>
set -euo pipefail

# iPhone 17 Pro Max (6.9" = 1320x2868, the ASC iPhone size). Override for iPad.
UDID="${UDID:-3BCCA0F0-94B0-4A99-83AA-5333E45B0489}"
BID="${BID:-net.smigi.worldward}"
OUT="${OUT:-$HOME/Desktop/Worldward-Screenshots/raw/iOS}"
# Seconds to wait after launch before capturing. Raise if shots come out mid-load.
SETTLE="${SETTLE:-6}"

# The 22 App Store Connect-supported localizations (of the app's 29).
# Excluded because ASC has no screenshot localization for them: bg et lv lt mt ga eo
LANGS="${LANGS:-en de fr es it nl pt-PT pt-BR sv da fi el cs sk sl hr hu ro pl ja ko zh-Hans}"
SCREENS="${SCREENS:-map been countryDetail going trip packing stats achievements wrapped share}"
MODES="${MODES:-light dark}"

command -v xcrun >/dev/null || { echo "xcrun not found"; exit 1; }
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

total=0
for LANG in $LANGS; do
  # AppleLocale wants underscores (pt-BR -> pt_BR); AppleLanguages wants the tag.
  LOCALE="${LANG//-/_}"
  for MODE in $MODES; do
    DIR="$OUT/$LANG/$MODE"
    mkdir -p "$DIR"
    i=1
    for S in $SCREENS; do
      xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
      sleep 1
      xcrun simctl launch "$UDID" "$BID" \
        -UITEST -screen "$S" -appearance "$MODE" \
        -AppleLanguages "($LANG)" -AppleLocale "$LOCALE" >/dev/null
      sleep "$SETTLE"
      printf -v N "%02d" "$i"
      xcrun simctl io "$UDID" screenshot --type=png "$DIR/$N-$S.png" >/dev/null 2>&1
      echo "  $LANG/$MODE/$N-$S.png"
      i=$((i + 1))
      total=$((total + 1))
    done
  done
done

xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
echo
echo "Done: $total screenshots under $OUT"
echo "These raw captures are the backup — the framing step must never overwrite them."
