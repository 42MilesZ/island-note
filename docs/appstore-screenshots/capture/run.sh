#!/bin/bash
# Island Note App Store screenshot capture. Uses a temporary clone, a bare debug
# binary, demo notes and a temp config dir. Never touches the user's notes or prefs.
set -u
W=/tmp/islandnote-shots-run
SRC="$W/src"
OUT="$W/out"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$W" "$OUT"
PREF="$HOME/Library/Preferences/IslandNote.plist"
[[ -e "$PREF" ]] && PREF_EXISTED=1 || PREF_EXISTED=0
if [[ -n "${REBUILD:-}" || ! -x "$SRC/.build/debug/IslandNote" ]]; then
  rm -rf "$SRC"
  git clone -q "$HOME/Projects/island-note" "$SRC" && git -C "$SRC" checkout -q ccba707 && git -C "$SRC" apply "$HERE/shots-harness.patch" || { echo "clone/patch failed"; exit 1; }
  cp "$SRC/Resources/Info.plist" "$W/shots-Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.projects.island-note.shots" -c "Set :CFBundleShortVersionString 1.0.1" -c "Set :CFBundleVersion 9" "$W/shots-Info.plist"
  (cd "$SRC" && swift build --product IslandNote -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$W/shots-Info.plist" 2>&1 | grep -E "error:|warning: unre|Compiling|Build complete" | grep -v "^Compiling" | head -20) || exit 1
fi
BIN="$SRC/.build/debug/IslandNote"
[[ -x "$BIN" ]] || { echo "no binary"; exit 1; }
NOTEDIR="/Users/Shared/Island Note"
SHARED_EXISTED=0; [[ -e "$NOTEDIR" ]] && SHARED_EXISTED=1
mkdir -p "$NOTEDIR"
for lang in zh en; do
  if [[ $lang == zh ]]; then AL="(zh-Hans)"; else AL="(en)"; fi
  for state in ${STATES:-rest hover expanded floating:420:-330 docking:0:-280:0.72 settings}; do
    name="${state%%:*}"
    cfg="$W/cfg-$lang-$name"; rm -rf "$cfg"; mkdir -p "$cfg"
    if [[ $name == expanded ]]; then cp "$HERE/note-$lang-short.md" "$NOTEDIR/Island Note.md"; else cp "$HERE/note-$lang.md" "$NOTEDIR/Island Note.md"; fi
    json="$OUT/$lang-$name.json"; rm -f "$json"
    ISLAND_SHOTS_NOTE="$NOTEDIR/Island Note.md" ISLAND_SHOTS_CONFIG="$cfg" ISLAND_SHOTS_STATE="$state" ISLAND_SHOTS_OUT="$json" \
      "$BIN" -AppleLanguages "$AL" -AppleLocale "${lang/zh/zh_CN}" >"$W/log-$lang-$name.txt" 2>&1 &
    pid=$!
    for i in $(seq 1 40); do [[ -s "$json" ]] && break; sleep 0.25; done
    sleep 0.3
    if [[ -s "$json" ]]; then
      for n in $(python3 -c "import json,sys;[print(w['number']) for w in json.load(open('$json'))['windows']]"); do
        screencapture -x -o -l "$n" "$OUT/$lang-$name-w$n.png"
        [[ $name == settings ]] && screencapture -x -l "$n" "$OUT/$lang-$name-w$n-shadow.png"
      done
    else echo "no json for $lang $name"; fi
    kill "$pid" 2>/dev/null; sleep 0.8; kill -9 "$pid" 2>/dev/null
  done
done
rm -f "$NOTEDIR/Island Note.md"; [[ $SHARED_EXISTED == 0 ]] && rm -rf "$NOTEDIR"
[[ $PREF_EXISTED == 0 ]] && rm -f "$PREF"
[[ $PREF_EXISTED == 0 ]] && { defaults delete IslandNote >/dev/null 2>&1 || true; }
defaults delete local.projects.island-note.shots >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/local.projects.island-note.shots.plist"
ls -la "$OUT" | head -80
