#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_flags=(-Xswiftc -DISLAND_EVENT_PROBE)
probe_name=event-probe
probe_build=202610131
if [[ "${PROBE_GESTURE_SNAPSHOT:-0}" == 1 ]]; then
    probe_name=event-probe-native
    probe_build=202610133
    probe_flags+=(-Xswiftc -DISLAND_GESTURE_SNAPSHOT)
fi
scratch="$PWD/.build/$probe_name"
if [[ "${PROBE_LAYER_DISPLAY:-0}" == 1 ]]; then
    probe_name=event-probe-layer
    probe_build=202610135
    probe_flags+=(-Xswiftc -DISLAND_LAYER_DISPLAY)
    scratch="$PWD/.build/$probe_name"
fi
if [[ "${PROBE_RESIZE_FIX:-0}" == 1 ]]; then
    probe_name=event-probe-resize-fix
    probe_build=202610136
    scratch="$PWD/.build/$probe_name"
fi
swift_bin="${SWIFT_BIN:-swift}"
"$swift_bin" build -c release --scratch-path "$scratch" --product IslandNote --disable-sandbox \
    "${probe_flags[@]}" -Xswiftc -debug-prefix-map -Xswiftc "$PWD=."
bin_dir="$("$swift_bin" build -c release --scratch-path "$scratch" --show-bin-path)"
"$bin_dir/IslandNote" --event-probe-self-test
app="$scratch/IslandNote-Diagnostics.app"
if [[ -e "$app" ]]; then mv "$app" "$scratch/previous-probe-$(date +%s).app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/IslandNote" "$app/Contents/MacOS/IslandNote"
cp -R "$bin_dir/IslandNote_IslandNote.bundle" "$app/Contents/Resources/"
for resource in AppIcon.icns ThirdPartyNotices.txt PrivacyInfo.xcprivacy; do
    cp "Resources/$resource" "$app/Contents/Resources/"
done
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :NSPrincipalClass IslandDiagnosticApplication' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${PROBE_BUILD_NUMBER:-$probe_build}" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION:-1.0}" "$app/Contents/Info.plist"
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identities=()
    while IFS= read -r item; do identities+=("$item"); done < <(
        security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p'
    )
    [[ ${#identities[@]} == 1 ]] || { echo 'Set SIGN_IDENTITY to one installed Developer ID Application identity.' >&2; exit 1; }
    identity="${identities[0]}"
fi
[[ "$identity" != '-' ]] || { echo 'The probe must keep the installed app signing identity.' >&2; exit 1; }
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
echo "Diagnostic build ready: $app"
