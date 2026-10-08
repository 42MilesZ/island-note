# Island Note

A small macOS scratchpad in a black capsule at the top of the screen. Hover to open it, write with live-rendered Markdown, and move away or press `Esc` to collapse it.

Drag the empty header beside the status dot to pull the note out into an always-on-top floating panel. Hovering the header shows a rounded white highlight at 10% opacity. A short movement stretches the bubble connection; pulling farther separates it with one trackpad haptic. The shadow spreads and shifts down while dragging, then settles when released. Floating notes stay open when the pointer leaves or another app is clicked. The text, selection, undo history and scroll position stay in the same editor.

Move any part of the drag strip near the capsule to preview docking: the contours reach toward each other with a gentle magnetic pull. Contour, connection and attraction follow distance continuously, beginning before the capture range; thresholds only govern haptics and the decision to dock on release. Entering and leaving the docking range each produce one haptic, paired with the welcoming or retreating contour. Release to merge back with one haptic and restore automatic collapse. Moving away cancels the preview; the entry and exit ranges differ to avoid jitter. Release an unfinished separation to return without a haptic. `Esc` also returns a floating panel and collapses it. Return flights can be interrupted by a new drag. Shadow, contour and position transitions respect Reduce Motion; screen changes update the docking target and keep floating headers reachable. Interaction logs use the `local.projects.island-note` subsystem with category `PanelDrag`, without note contents.

While open, either docked or floating, spread two fingers on the trackpad to enlarge the panel from 460 × 275 to 690 × 550 points (1.5× width, 2× height). Pinch inward to restore the default size. A pinch can start immediately after releasing a floating panel; its size animation takes over from the release animation. Floating panels adjust their position along with the resize to stay on screen. Each gesture switches once with a gentle spring and a haptic pulse; text stays the same size. The selected size is kept until the app quits, including after docking again. Double-click still selects text normally.

Notes with three or more Markdown headings show a small outline in the left margin. Bar lengths reflect heading levels, and the current section is highlighted as you scroll. Hover a bar to preview its title with a light haptic tick; click to scroll smoothly to that section without moving the text selection or adding another haptic pulse. Below three headings, the outline is hidden and does not respond to hovering. Longer outlines can scroll independently, and Reduce Motion is respected.

## Run

Requires macOS 14 or later and Swift 5.9 or later.

```bash
make run
```

`make package` builds a fresh signed `IslandNote.app` without opening it, with an application icon and version metadata. Previous bundles are kept recoverable under the ignored `.build/` directory.

## Flomo sync

Click the top-right status dot, open **Flomo Sync…** in the app/context menu, or press **⌘,** while editing. Enter your [Flomo MAX personal token](https://help.flomoapp.com/advance/mcp/token.html) in the secure field. The token stays in macOS Keychain, separate from Codex's connector. To link an existing memo, choose **Find Existing Memo…**, search for words from its text, select a preview, then click Connect. Search reads at most 50 previews; sync fetches the complete selected memo before comparing or writing. No memo URL or ID is required. You can still paste one directly. Leave the memo field empty only to create a new dedicated memo. Connecting an unequal existing memo shows both complete versions. **Merge Both** preserves the local text followed by the Flomo text in one document, backs up both originals, and updates that same memo. It never creates a second memo. Merges over the size limit are blocked.

Island Note sends saved edits after 3 seconds of inactivity and checks Flomo every 60 seconds while the app runs, and whenever the panel opens. Changes on either side sync automatically when only one copy has changed since the last verified sync. A single small dot in the top-right combines local saves and Flomo sync: a brief green pulse after a local save, a gentle neutral pulse while syncing, quiet gray at rest, amber when sync needs attention, and red if local saving fails. Local save errors take priority, and a save pulse never hides a sync warning. Hover shows a compact one-line card inside the panel (for example, Saved · Synced), above its content. Click opens the full explanation, last verified time, and actions. State changes respect Reduce Motion. Synced appears only after verification and never while a newer local edit is pending. If both copies changed, click the status to review them. Pause/resume and Sync Now are available in settings. Closing the app stops synchronization; the local file still saves immediately.

The document limit is **30,000 Unicode scalars**. Oversized edits are rejected as a whole, never truncated. Existing larger files remain readable and can be shortened. Flomo needs a small amount of extra room for heading escapes and list spacing near the limit, so a full local document may need shortening to sync.

The tested profile is paragraphs, `#`–`######` headings, `**bold**`, and ordered/unordered lists. Heading markers are escaped in transport so they remain literal text in Flomo and return as Markdown headings in Island Note. Extra blank lines, loose-list separators, and cosmetic trailing whitespace are normalized; Markdown's two-space hard breaks are retained. Checkboxes, tables, code blocks, blockquotes, Markdown links/images and wiki-links pause sync until removed; the local source is still saved, with no automatic conversion. Bare URLs that Flomo returns as an identical-label link remain bare URLs locally. Verification tolerates known added paragraph separators, nested-list tab spacing, and harmless inline punctuation escapes without rewriting the local source. Blank lines and empty draft bullets are treated as cosmetic, so they never require review and local spacing is retained. Missing words, changed nonempty list structure, or conflicting content edits still require review. Literal word-internal tildes are escaped on every upload so file paths keep their characters. A pending upload from the older encoder can repair this specific tilde loss once, using a version-checked update and backup; unexpected text loss is never auto-accepted. Local and remote baselines are stored separately. Interrupted merges record their intent before replacing the local file, preventing duplicate appends after restart. The empty `- -` placeholder is transported as literal text. Other formatting is subject to conservative readback verification. Flomo attachments and incomplete/truncated reads always block sync.

Every upload is read back before accepting a new shared baseline. Updates include Flomo's version timestamp. Network failures retain pending work; an uncertain create is never retried automatically, to avoid duplicate memos. If a create's response is lost, find the created memo in Flomo and enter its URL. Empty notes never erase the other copy automatically. Pulls check the editor and disk again, skip active input composition, and use macOS file coordination. Editors that do not participate in file coordination can still race at the filesystem level; avoid editing the same file in multiple apps simultaneously.

Sync state and replacement backups are local to `~/Library/Application Support/IslandNote/` (`flomo-sync.json` and `Sync Backups/`). Backups are kept before remote pulls and explicit replacements. Logs use the `local.projects.island-note` subsystem with category `FlomoSync`; they contain state/error messages, never the token or document body.

## Storage

New installations use `~/Library/Application Support/IslandNote/Island Note.md`.
To use an existing Markdown file, set its absolute path in the local-only file
`~/Library/Application Support/IslandNote/settings.json`:

```json
{"notePath": "/path/to/your/note.md"}
```

An invalid configuration or a missing selected file blocks saving instead of
silently creating or switching to another document. Changes save automatically
while typing and when the panel closes. Local notes and sync backups are never
part of the source repository.

## Signing and distribution

`make package` uses the single installed **Developer ID Application** identity,
or an explicit `SIGN_IDENTITY`, with hardened runtime and a secure timestamp.
It stops on signing errors; it never silently falls back to ad-hoc signing.
Keep the bundle identifier and Developer ID team stable across updates so macOS
Keychain can recognize the same app. Switching from an old ad-hoc build may need
one final Keychain approval. Normal updates then retain the same designated
requirement; a locked Keychain can still require unlocking.

`NOTARY_PROFILE=your-keychain-profile make notarize` submits the signed bundle
to Apple, waits for acceptance, staples the ticket, verifies Gatekeeper, and
writes `dist/IslandNote.zip`. Notarization credentials stay in Keychain. Run
`make package-dev` only for disposable ad-hoc development builds.

Before sharing code, run `make audit`. The repository ignores private notes,
sync state, local environment files, signing keys, certificates, and release
artifacts. Review staged changes too: an ignore rule cannot protect an already
tracked file or remove older Git history.

Built with Swift, AppKit, and [SwiftMarkdownEngine](https://github.com/nodes-app/swift-markdown-engine).

## TestFlight (macOS)

`make testflight` generates the Xcode project from `project.yml`, archives a
universal Apple Silicon / Intel app, exports using App Store Connect signing,
validates the package, then uploads it. XcodeGen and Xcode 26 are required.
`ASC_KEY_ID` and `ASC_ISSUER_ID` come from the shell environment; the private key
stays in `~/.appstoreconnect/private_keys/`. The first beta uses build `3`. Set `BUILD_NUMBER` to a new increasing integer
for subsequent uploads. An App Store Connect app record
for `local.projects.island-note` must exist before uploading.

This target defines `ISLAND_TESTFLIGHT` and excludes all Flomo networking,
credentials, settings and sync implementations at compile time. It has App
Sandbox enabled with **no network or Keychain access entitlements**. Its note is
stored under the sandbox container's Application Support directory. Existing
unsandboxed notes and Flomo configuration are not imported. The direct
distribution build from `make package` retains its existing Flomo support.

The same uploaded build is intended for both internal and external testing
(`testFlightInternalTestingOnly` is false). Upload acceptance, build processing,
internal testing and external Beta App Review are separate states: check the
exact uploaded build before reporting availability. Reviewers do not need a
login or a Flomo token.
