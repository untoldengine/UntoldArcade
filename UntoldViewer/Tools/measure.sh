#!/bin/sh
# Records one measurement pass of UntoldViewer with Instruments and opens the trace:
#   Tools/measure.sh <device UDID or name> [object] [template]
# The app runs `-measure`: the object through the engine, then RealityKit, one tour loop
# each, with signpost intervals (Points of Interest: Engine empty / Engine <object> /
# RealityKit <object> / Measure <renderer>). Read the GPU time per interval on the
# RealityKit Metrics track; the object's cost is the object interval minus the empty one.
#
# The app is launched with devicectl and the recording takes all processes: xctrace's own
# --launch and --attach lose the device while starting and kill the app with them, and
# RealityKit renders in the system's render server anyway, which only an all-process
# recording sees. Instruments needs a stable link to the headset: the Developer Strap
# (USB-C) rather than Wi-Fi. The app must already be installed (one run from Xcode).
# The bundle identifier follows Config/Local.xcconfig when it sets BUNDLE_ID_PREFIX.
set -e
DEVICE="${1:?device UDID or name (xcrun xctrace list devices)}"
OBJECT="${2:-board}"
TEMPLATE="${3:-RealityKit Trace}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="com.untoldengine"
if [ -f "$HERE/Config/Local.xcconfig" ]; then
    LOCAL=$(sed -n 's/^[[:space:]]*BUNDLE_ID_PREFIX[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$HERE/Config/Local.xcconfig" | tail -1)
    [ -n "$LOCAL" ] && PREFIX="$LOCAL"
fi
BUNDLE="$PREFIX.untoldviewer"
OUT="Measure-$OBJECT.trace"
rm -rf "$OUT"
echo "launching $BUNDLE on $DEVICE, recording all processes for 75 s → $OUT"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE" -- -measure -object "$OBJECT" -hideWindow
xcrun xctrace record --template "$TEMPLATE" --device "$DEVICE" --all-processes --time-limit 75s --output "$OUT"
# A hollow trace means Instruments had no link to the device; check with:
#   xcrun xctrace export --input "$OUT" --toc | grep -c "<process "
open "$OUT"
