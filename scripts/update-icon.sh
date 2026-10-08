#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
staging="$(mktemp -d "$PWD/.build/icon.XXXXXX")"
iconset="$staging/AppIcon.iconset"
trap 'rm -f "$iconset"/icon_*.png; rmdir "$iconset" "$staging"' EXIT
mkdir -p "$iconset"
destination="${1:-Resources/AppIcon.icns}"
swift -module-cache-path "$PWD/.build/IconModuleCache" scripts/make-icon.swift "$iconset"
iconutil -c icns "$iconset" -o "$destination"
echo "Updated $destination"
