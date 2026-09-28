# Island Note

A small macOS scratchpad in a black capsule at the top of the screen. Hover to open it, write with live-rendered Markdown, and move away or press `Esc` to collapse it.

While open, spread two fingers on the trackpad to enlarge the panel from 460 × 275 to 690 × 550 points (1.5× width, 2× height). Pinch inward to restore the default size. Each gesture switches once with a gentle spring and a haptic pulse; text stays the same size. The selected size is kept until the app quits. Double-click still selects text normally.

Notes with three or more Markdown headings show a small outline in the left margin. Bar lengths reflect heading levels, and the current section is highlighted as you scroll. Hover a bar to preview its title; click to scroll smoothly to that section without moving the text selection. Hover and navigation have light haptic feedback. Longer outlines can scroll independently, and Reduce Motion is respected.

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
