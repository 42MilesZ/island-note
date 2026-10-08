# Island Note

A small macOS scratchpad in a black capsule at the top of the screen. Hover to open it, write with live-rendered Markdown, and move away or press `Esc` to collapse it.

Drag the empty header beside the status dot to pull the note out into an always-on-top floating panel. Hovering the header shows a rounded white highlight at 10% opacity. A short movement stretches the bubble connection; pulling farther separates it with one trackpad haptic. The shadow spreads and shifts down while dragging, then settles when released. Floating notes stay open when the pointer leaves or another app is clicked. The text, selection, undo history and scroll position stay in the same editor.

Move any part of the drag strip near the capsule to preview docking: the contours reach toward each other with a gentle magnetic pull. Contour, connection and attraction follow distance continuously, beginning before the capture range; thresholds only govern haptics and the decision to dock on release. Entering and leaving the docking range each produce one haptic, paired with the welcoming or retreating contour. Release to merge back with one haptic and restore automatic collapse. Moving away cancels the preview; the entry and exit ranges differ to avoid jitter. Release an unfinished separation to return without a haptic. `Esc` also returns a floating panel and collapses it. Return flights can be interrupted by a new drag. Shadow, contour and position transitions respect Reduce Motion; screen changes update the docking target and keep floating headers reachable. Interaction logs use the `local.projects.island-note` subsystem with category `PanelDrag`, without note contents.

Pulling the note out smoothly changes the wide docked panel into a taller, nearly square floating panel: 420 × 460 points by default. The grabbed position stays under the pointer as the shape changes. Drag any of its four edges or four corners to resize freely; the opposite edge stays fixed. The minimum is 320 × 280 points, and the maximum is 1200 × 1000 points or the available display/canvas size. Each corner has a 48 × 48-point hover and click area, reaching 34 points inside and 14 points outside the panel; edge strips are 14 points wide. Hovering shows the matching resize arrow before clicking, including on an inactive floating panel. macOS 15 and later use the system frame-resize cursors; macOS 14 retains the custom diagonal fallback. Hover and cursor rectangles share the mouse-down geometry and exclude the full status-button footprint. The panel resolves the cursor after the editor's event handlers to prevent its I-beam from overriding corner feedback. The note body and central header retain normal editing and dragging behavior.

Both docked and floating panels resize continuously: each native magnification delta scales the target width and height proportionally by `1 + delta`, with no preset steps, trigger threshold or extra speed multiplier. Faster finger movement delivers target changes faster; gesture amplitude controls the scale. The visible panel follows that target with a critically damped curve (frequency 12): a gentle acceleration, most of the change in roughly 0.3 seconds, and a soft landing after release. New deltas preserve the current position and velocity; direction changes decelerate smoothly instead of restarting a curve. Reduce Motion applies dimensions directly. Edge resizing remains direct. A docked panel keeps its top attached to the island and its horizontal center fixed, growing sideways and downward from its default 460 × 275 points; its minimum is 320 × 190 points. A floating panel stays centered during a pinch, moving only as needed to fit the display. Both are bounded by the available screen and canvas. Its aspect ratio and text size stay unchanged. A pinch can start immediately after releasing a floating panel and takes control from an in-progress size morph. A zero-motion gesture resumes the previous morph or follow without jumping to the target. The first size change produces a haptic, and reaching a size limit produces one further haptic; reversing at a limit updates the target immediately. Docked and floating dimensions are remembered independently until the app quits; docking restores the custom docked size, and the next pull-out restores the floating dimensions. Grabbing a transitioning panel keeps the current viewport under the pointer, and releasing a stationary grab resumes the size transition. Double-click still selects text normally.

Pinches received during a return to the island accumulate continuously against the docked size and follow the same damped curve after arrival, including when the gesture continues across arrival. During opening, the editor's full footprint accepts a pinch even while its contour is still expanding. A held header or edge resize temporarily owns the interaction; the next pinch is accepted after release.

## Settings and privacy

Open **Settings…** from the island or editor's context menu, or press **⌘,**.
The panel retracts while settings or the policy is open so its floating level cannot hide those windows.
Flomo and local diagnostics are independent opt-in features, both off by default.
The interface follows the system language, using Simplified Chinese for Chinese and English otherwise.
There is no in-app language selector; previous overrides are ignored.
**Privacy Policy** shows the complete policy bundled with the app, including while offline.
The public policy is in [docs/privacy-policy.md](docs/privacy-policy.md).

Turn on **Record Local Diagnostics**, reproduce an issue, then **Export Report…**.
**Clear Records** removes only the app's diagnostic files. Turning collection off retains prior records.
Reports contain event phases, sampled magnification, dimensions, focus/interaction states and app/system versions;
they exclude note text, file names, account details, credentials and screenshots. Nothing is uploaded automatically.
The most recent 300 events stay in the app's Application Support `IslandNote/Diagnostics/` directory
(inside the container for the sandboxed store app). Writes are batched off the UI thread;
changed magnification is sampled at most every 0.1 seconds, with lifecycle events and decisions retained.
Exported copies remain at the location you choose. Findings are interaction rules and may not identify every cause.


## Run

Requires macOS 14 or later and Swift 5.9 or later.

```bash
make run
```

`make package` builds a fresh signed `IslandNote.app` without opening it, with an application icon and version metadata. Previous bundles are kept recoverable under the ignored `.build/` directory.

## Flomo sync

In **Settings…**, enable **Flomo Sync**, review the data-use notice, then choose **Configure Flomo…**. The top-right dot opens Settings or takes you directly to a sync issue that needs review. **Flomo Sync…** appears in context menus only while the extension is enabled. Enter your [Flomo MAX personal token](https://help.flomoapp.com/advance/mcp/token.html) in the secure field. The token stays in macOS Keychain. To link an existing memo, choose **Find Existing Memo…**, search for words from its text, select a preview, then click Connect. Search reads at most 50 previews; sync fetches the complete selected memo before comparing or writing. No memo URL or ID is required. You can still paste one directly. Leave the memo field empty only to create a new dedicated memo. Connecting an unequal existing memo shows both complete versions. **Merge Both** preserves the local text followed by the Flomo text in one document, backs up both originals, and updates that same memo. It never creates a second memo. Merges over the size limit are blocked.

Island Note sends saved edits after 3 seconds of inactivity and checks Flomo every 60 seconds while the app runs, and whenever the panel opens. Changes on either side sync automatically when only one copy has changed since the last verified sync. A single small dot in the top-right combines local saves and Flomo sync: a brief green pulse after a local save, a gentle neutral pulse while syncing, quiet gray at rest, amber when sync needs attention, and red if local saving fails. Local save errors take priority, and a save pulse never hides a sync warning. Hover shows a compact one-line card inside the panel (for example, Saved · Synced), above its content. Click opens the full explanation, last verified time, and actions. State changes respect Reduce Motion. Synced appears only after verification and never while a newer local edit is pending. If both copies changed, click the status to review them. Pause/resume and Sync Now are available in settings. Disabling the extension stops subsequent HTTP requests and retains the previous automatic-sync or pause preference. An already-issued write may finish; its returned ID and verification intent are retained. Quick re-enabling cannot revive an old handshake. Closing the app stops synchronization; the local file still saves immediately.

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
stays in `~/.appstoreconnect/private_keys/`. Build `3` was previously uploaded. The current release version is `1.0`, with default build `4`. Set `BUILD_NUMBER` to a new increasing integer
for subsequent uploads. An App Store Connect app record
for `local.projects.island-note` must exist before uploading.

This target defines `ISLAND_APP_STORE`, enables App Sandbox and includes the same optional
Flomo functionality as direct distribution. Outgoing network access supports the optional
Flomo connection; selected-file read/write access supports explicit diagnostic exports.
Default startup does not read a Flomo token or initialize synchronization while its switch is off.
Notes are stored under the sandbox container's Application Support directory; existing unsandboxed
notes and sync configuration are not imported. Keychain is used for the personal token after opt-in.
The privacy manifest declares the app's own preferences and elapsed-time API use, and optional
user-content/search-history transfer for sync functionality, without tracking.

The same uploaded build is intended for both internal and external testing
(`testFlightInternalTestingOnly` is false). Upload acceptance, build processing,
internal testing and external Beta App Review are separate states: check the
exact uploaded build before reporting availability. The core local-note features do not require a login or a Flomo token. Review notes should
explain that Flomo is optional and requires the user's own Flomo MAX personal token.
