#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identities=()
    while IFS= read -r item; do identities+=("$item"); done < <(
        security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p'
    )
    if [[ ${#identities[@]} != 1 ]]; then
        echo "Set SIGN_IDENTITY to one installed Developer ID Application identity." >&2
        exit 1
    fi
    identity="${identities[0]}"
fi
swift build -c release --product IslandNote --disable-sandbox \
    -Xswiftc -debug-prefix-map -Xswiftc "$PWD=."
bin_dir="$(swift build -c release --show-bin-path)"
# Build a fresh bundle so stray files can never enter a signed release.
staging="$(mktemp -d "$PWD/.build/package.XXXXXX")"
app="$staging/IslandNote.app"
output="$PWD/IslandNote.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" .build/AppIcon.iconset
cp "$bin_dir/IslandNote" "$app/Contents/MacOS/IslandNote"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION:-0.2.0}" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-2}" "$app/Contents/Info.plist"
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
if [[ "$identity" == "-" ]]; then
    echo "Development-only ad-hoc build: Keychain approval may recur after updates." >&2
    codesign --force --sign - "$app"
else
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict "$app"
# Keep the previous bundle recoverable instead of deleting user-added files.
if [[ -e "$output" ]]; then mv "$output" "$staging/previous.app"; fi
mv "$app" "$output"
echo "Built and verified $output"
