# Island Note

A small macOS scratchpad in a black capsule at the top of the screen. Hover to open it, write with live-rendered Markdown, and move away or press `Esc` to collapse it.

While open, spread two fingers on the trackpad to enlarge the panel from 460 × 275 to 690 × 550 points (1.5× width, 2× height). Pinch inward to restore the default size. Each gesture switches once with a gentle spring and a haptic pulse; text stays the same size. The selected size is kept until the app quits. Double-click still selects text normally.

Notes with three or more Markdown headings show a small outline in the left margin. Bar lengths reflect heading levels, and the current section is highlighted as you scroll. Hover a bar to preview its title with a light haptic tick; click to scroll smoothly to that section without moving the text selection or adding another haptic pulse. Below three headings, the outline is hidden and does not respond to hovering. Longer outlines can scroll independently, and Reduce Motion is respected.

## Run

Requires macOS 14 or later and Swift 5.9 or later.

```bash
make run
```

`make package` builds `IslandNote.app` without opening it.

## Flomo sync

Click the top-right status dot, open **Flomo Sync…** in the app/context menu, or press **⌘,** while editing. Enter your [Flomo MAX personal token](https://help.flomoapp.com/advance/mcp/token.html) in the secure field. The token stays in macOS Keychain, separate from Codex's connector. To link an existing memo, choose **Find Existing Memo…**, search for words from its text, select a preview, then click Connect. Search reads at most 50 previews; sync fetches the complete selected memo before comparing or writing. No memo URL or ID is required. You can still paste one directly. Leave the memo field empty only to create a new dedicated memo. Connecting an unequal existing memo shows both complete versions. **Merge Both** preserves the local text followed by the Flomo text in one document, backs up both originals, and updates that same memo. It never creates a second memo. Merges over the size limit are blocked.

Island Note sends saved edits after 3 seconds of inactivity and checks Flomo every 60 seconds while the app runs, and whenever the panel opens. Changes on either side sync automatically when only one copy has changed since the last verified sync. A single small dot in the top-right combines local saves and Flomo sync: a brief green pulse after a local save, a gentle neutral pulse while syncing, quiet gray at rest, amber when sync needs attention, and red if local saving fails. Local save errors take priority, and a save pulse never hides a sync warning. Hover shows the exact state, explanation, and last verified time; click opens review or settings. State changes respect Reduce Motion. Synced appears only after verification and never while a newer local edit is pending. If both copies changed, click the status to review them. Pause/resume and Sync Now are available in settings. Closing the app stops synchronization; the local file still saves immediately.

The document limit is **30,000 Unicode scalars**. Oversized edits are rejected as a whole, never truncated. Existing larger files remain readable and can be shortened. Flomo needs a small amount of extra room for heading escapes and list spacing near the limit, so a full local document may need shortening to sync.

The tested profile is paragraphs, `#`–`######` headings, `**bold**`, and ordered/unordered lists. Heading markers are escaped in transport so they remain literal text in Flomo and return as Markdown headings in Island Note. Extra blank lines, loose-list separators, and cosmetic trailing whitespace are normalized; Markdown's two-space hard breaks are retained. Checkboxes, tables, code blocks, blockquotes, Markdown links/images and wiki-links pause sync until removed; the local source is still saved, with no automatic conversion. Bare URLs that Flomo returns as an identical-label link remain bare URLs locally. Verification tolerates known added paragraph separators, nested-list tab spacing, and harmless inline punctuation escapes without rewriting the local source. Blank lines and empty draft bullets are treated as cosmetic, so they never require review and local spacing is retained. Missing words, changed nonempty list structure, or conflicting content edits still require review. Literal word-internal tildes are escaped on every upload so file paths keep their characters. A pending upload from the older encoder can repair this specific tilde loss once, using a version-checked update and backup; unexpected text loss is never auto-accepted. Local and remote baselines are stored separately. Interrupted merges record their intent before replacing the local file, preventing duplicate appends after restart. The empty `- -` placeholder is transported as literal text. Other formatting is subject to conservative readback verification. Flomo attachments and incomplete/truncated reads always block sync.

Every upload is read back before accepting a new shared baseline. Updates include Flomo's version timestamp. Network failures retain pending work; an uncertain create is never retried automatically, to avoid duplicate memos. If a create's response is lost, find the created memo in Flomo and enter its URL. Empty notes never erase the other copy automatically. Pulls check the editor and disk again, skip active input composition, and use macOS file coordination. Editors that do not participate in file coordination can still race at the filesystem level; avoid editing the same file in multiple apps simultaneously.

Sync state and replacement backups are local to `~/Library/Application Support/IslandNote/` (`flomo-sync.json` and `Sync Backups/`). Backups are kept before remote pulls and explicit replacements. Logs use the `local.projects.island-note` subsystem with category `FlomoSync`; they contain state/error messages, never the token or document body.

## Storage

Island Note edits one document directly in the local Obsidian vault:

`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Miles-Vault/Dairy notes/Island Note.md`

Changes save automatically while typing and when the panel closes. The Vault folder must already exist. The original `notes/scratch.txt` is kept locally as a backup and remains ignored by Git.

Built with Swift, AppKit, and [SwiftMarkdownEngine](https://github.com/nodes-app/swift-markdown-engine).
