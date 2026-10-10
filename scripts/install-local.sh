#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source="$PWD/IslandNote.app"
destination="${1:-$HOME/Applications/IslandNote.app}"
identifier="local.projects.island-note"

codesign --verify --deep --strict "$source"
signature="$(codesign -dvv "$source" 2>&1)"
requirement="$(codesign -d -r- "$source" 2>&1 | sed -n 's/^designated => //p')"
signed_identifier="$(printf '%s\n' "$signature" | sed -n 's/^Identifier=//p')"
if [[ "$signature" != *"Authority=Developer ID Application:"* || "$signed_identifier" != "$identifier" || -z "$requirement" || "$requirement" == *cdhash* ]]; then
    echo "Local installation requires a stable Developer ID signature. Run make package; package-dev is disposable." >&2
    exit 1
fi

if [[ -e "$destination" ]]; then
    installed_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
    if [[ "$installed_identifier" != "$identifier" ]]; then
        echo "Destination belongs to another app; nothing was replaced." >&2
        exit 1
    fi
    previous_signature="$(codesign -dvv "$destination" 2>&1)"
    if [[ "$previous_signature" == *"Authority=Developer ID Application:"* ]]; then
        previous_requirement="$(codesign -d -r- "$destination" 2>&1 | sed -n 's/^designated => //p')"
        # A different signing team/channel would lose the existing Keychain identity.
        codesign --verify --strict -R="$previous_requirement" "$source"
    else
        echo "Migrating to stable signing; macOS may request one final Keychain approval."
    fi
fi

processes="$(ps -axo comm=)"
while IFS= read -r executable; do
    if [[ "$executable" == "$destination/Contents/MacOS/IslandNote" ]]; then
        echo "Quit Island Note normally before installing, so pending edits are saved." >&2
        exit 1
    fi
done < <(printf '%s\n' "$processes" | sed 's/^[[:space:]]*//')

mkdir -p "$PWD/.build" "$(dirname "$destination")"
backup="$(mktemp -d "$PWD/.build/local-install.XXXXXX")"
had_previous=false
if [[ -e "$destination" ]]; then
    mv "$destination" "$backup/previous.app"
    had_previous=true
fi
rollback() {
    trap - ERR
    if [[ -e "$destination" ]]; then mv "$destination" "$backup/failed.app"; fi
    if [[ "$had_previous" == true ]]; then mv "$backup/previous.app" "$destination"; fi
    echo "Installation failed; previous app restored. Files retained at $backup." >&2
    exit 1
}
trap rollback ERR
ditto "$source" "$destination"
codesign --verify --deep --strict "$destination"
codesign --verify --strict -R="$requirement" "$destination"
trap - ERR
echo "Installed $destination; rollback retained at $backup."
