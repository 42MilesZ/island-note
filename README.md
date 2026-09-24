# Island Note

A small macOS scratchpad that lives in a black capsule at the top of the screen. Hover to open the editor; move away or press `Esc` to collapse it. Notes save automatically as plain text.

## Run

Requires macOS 13 or later and Swift 5.9 or later.

```bash
make run
```

This builds and opens `IslandNote.app`. Use `make package` to build the app without opening it.

## Notes

The app saves text to `notes/scratch.txt` when run from this project. That file is ignored by Git so your notes stay local. If the project directory is unavailable, the app uses `~/Projects/island-note/notes/scratch.txt` or `~/Library/Application Support/IslandNote/scratch.txt`.

Built with Swift and AppKit.
