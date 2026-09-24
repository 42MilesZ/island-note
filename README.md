# Island Note

A small macOS scratchpad in a black capsule at the top of the screen. Hover to open it, write with live-rendered Markdown, and move away or press `Esc` to collapse it.

## Run

Requires macOS 14 or later and Swift 5.9 or later.

```bash
make run
```

`make package` builds `IslandNote.app` without opening it.

## Storage

Island Note edits one document directly in the local Obsidian vault:

`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Miles-Vault/Dairy notes/Island Note.md`

Changes save automatically while typing and when the panel closes. The Vault folder must already exist. The original `notes/scratch.txt` is kept locally as a backup and remains ignored by Git.

Built with Swift, AppKit, and [SwiftMarkdownEngine](https://github.com/nodes-app/swift-markdown-engine).
