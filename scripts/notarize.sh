#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool Keychain profile.}"
app="$PWD/IslandNote.app"
codesign --verify --deep --strict "$app"
signature="$(codesign -dvv "$app" 2>&1)"
if [[ "$signature" != *"Authority=Developer ID Application:"* ]]; then
    echo "Notarization requires a Developer ID Application signature." >&2
    exit 1
fi
mkdir -p dist
archive="dist/IslandNote-notary-upload.zip"
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --keepParent "$app" dist/IslandNote.zip
echo "Notarized release: dist/IslandNote.zip"
