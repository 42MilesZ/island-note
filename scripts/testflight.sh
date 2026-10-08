#!/bin/bash
# Local universal macOS build; credentials remain in the environment/Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
key_path="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
[[ -f "$key_path" ]] || { echo 'App Store Connect key is missing.' >&2; exit 1; }
build_number="${BUILD_NUMBER:-5}"
[[ "$build_number" =~ ^[1-9][0-9]{0,3}$ ]] || { echo 'BUILD_NUMBER must be an increasing integer from 1 to 9999.' >&2; exit 1; }
archive_path="$PWD/.build/testflight/$build_number/IslandNote.xcarchive"
export_path="$PWD/.build/testflight/$build_number/export"
mkdir -p "$export_path" dist
./scripts/update-icon.sh
xcodegen generate
xcodebuild -project IslandNote.xcodeproj -scheme IslandNote \
    -destination 'generic/platform=macOS' -derivedDataPath .build/TestFlightDerived \
    -archivePath "$archive_path" archive CURRENT_PROJECT_VERSION="$build_number" \
    -allowProvisioningUpdates -authenticationKeyPath "$key_path" \
    -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -quiet
xcodebuild -exportArchive -archivePath "$archive_path" \
    -exportOptionsPlist Resources/ExportOptions.plist -exportPath "$export_path" \
    -allowProvisioningUpdates -authenticationKeyPath "$key_path" \
    -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -quiet
app="$archive_path/Products/Applications/IslandNote.app"
codesign --verify --deep --strict "$app"
lipo "$app/Contents/MacOS/IslandNote" -verify_arch arm64 x86_64
# Flomo is bundled in the sandboxed store build, and remains opt-in at runtime.
packages=("$export_path"/*.pkg)
[[ ${#packages[@]} == 1 && -f "${packages[0]}" ]] || { echo 'Export must produce exactly one macOS package.' >&2; exit 1; }
pkg="${packages[0]}"
cp "$pkg" "dist/IslandNote-TestFlight-$build_number.pkg"
xcrun altool --validate-app -f "$pkg" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
xcrun altool --upload-app -f "$pkg" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "Uploaded build $build_number. Check this exact build's processing and beta review states in App Store Connect."
