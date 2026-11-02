# Island Note

<img src="Resources/AppIcon.svg" width="128" height="128" alt="Island Note icon">

A small macOS scratchpad in a black capsule at the top of the screen. Hover to open it, write with live-rendered Markdown, and move away or press `Esc` to collapse it.

Drag the empty header beside the status dot to pull the note out into an always-on-top floating panel. Hovering the header shows a rounded white highlight at 10% opacity. A short movement stretches the bubble connection; pulling farther separates it with one trackpad haptic. The shadow spreads and shifts down while dragging, then settles when released. Floating notes stay open when the pointer leaves or another app is clicked. The text, selection, undo history and scroll position stay in the same editor.

Move any part of the drag strip near the capsule to preview docking: the contours reach toward each other with a gentle magnetic pull. Contour, connection and attraction follow distance continuously, beginning before the capture range; thresholds only govern haptics and the decision to dock on release. Entering and leaving the docking range each produce one haptic, paired with the welcoming or retreating contour. Release to merge back with one haptic and restore automatic collapse. Moving away cancels the preview; the entry and exit ranges differ to avoid jitter. Release an unfinished separation to return without a haptic. `Esc` also returns a floating panel and collapses it. Return flights can be interrupted by a new drag. Shadow, contour and position transitions respect Reduce Motion; screen changes update the docking target and keep floating notes within the minimum visible overlap. Interaction logs use the `local.projects.island-note` subsystem with category `PanelDrag`, without note contents.

Pulling the note out smoothly changes the wide docked panel into a taller, nearly square floating panel: 420 × 460 points by default. The grabbed position stays under the pointer as the shape changes. Drag any of its four edges or four corners to resize freely; the opposite edge stays fixed. The minimum is 320 × 280 points, and the maximum is 1200 × 1000 points or the available display/canvas size. Each corner has a 48 × 48-point hover and click area, reaching 34 points inside and 14 points outside the panel; edge strips are 14 points wide. Hovering shows the matching resize arrow before clicking, including on an inactive floating panel. macOS 15 and later use the system frame-resize cursors; macOS 14 retains the custom diagonal fallback. Hover and cursor rectangles share the mouse-down geometry and exclude the full status-button footprint. The panel resolves the cursor after the editor's event handlers to prevent its I-beam from overriding corner feedback. The note body and central header retain normal editing and dragging behavior.

Both docked and floating panels resize continuously: each native magnification delta scales the target width and height proportionally by `1 + delta`, with no preset steps, trigger threshold or extra speed multiplier. Faster finger movement delivers target changes faster; gesture amplitude controls the scale. Each gesture event updates the visible panel immediately, including direction changes and release, without a delayed animation tail. Edge resizing also follows input directly. Programmatic docking and aspect changes retain an explicit Ease In Out transition, with Reduce Motion support. A docked panel keeps its top attached to the island and its horizontal center fixed, growing sideways and downward from its default 460 × 275 points; its minimum is 320 × 190 points. A floating panel stays centered during a pinch, moving only as needed to retain at least 40 points of its width and height in the visible screen area. Floating notes can otherwise stay mostly offscreen, including at corners; the same overlap limit applies on release and after display changes. Both panels' sizes are bounded by the available screen and canvas. Its aspect ratio and text size stay unchanged. A pinch can start immediately after releasing a floating panel and takes control from an in-progress size morph. A zero-motion gesture resumes an interrupted aspect transition without jumping to the target. The first size change produces a haptic, and reaching a size limit produces one further haptic; reversing at a limit updates the target immediately. Docked and floating dimensions are remembered independently until the app quits; docking restores the custom docked size, and the next pull-out restores the floating dimensions. Grabbing a transitioning panel keeps the current viewport under the pointer, and releasing a stationary grab resumes the size transition. Double-click still selects text normally.

Pinches received during a return to the island accumulate against the docked size. On arrival, queued dimensions use Ease In Out; a continuing gesture immediately takes over that transition. During opening, the editor's full footprint accepts a pinch even while its contour is still expanding. A held header or edge resize temporarily owns the interaction; the next pinch is accepted after release. Edge releases are observed even outside the handle, and a pinch recovers an unfinished edge session if the physical mouse button is no longer pressed. Opening Settings retracts the note, including a floating note, after saving pending edits. Hover cannot reopen it over those windows; normal hover opening returns after they close. During resizing, the editor reflows visible text at its existing font size, retains its document height, and coalesces clip-view frame/bounds notifications. Release, cancellation, focus loss, keyboard input and scrolling restore normal sizing and commit final table/code-block geometry. Heading rows are created lazily; their full-document position refresh waits until resizing ends.

## Lists

Root list markers align with ordinary prose; each nested level adds 24 points.
All markers have a six-point visible gap before their text, with hanging indents
for wrapped lines. Source spaces and tabs remain intact and do not widen that
gap. Unordered markers render as equal-size solid circles, hollow circles, then
squares; their Markdown remains standard `-`, `+` or `*`. Existing ordered
numbers display exactly as stored. Structural list edits renumber siblings from
1 within each parent, including subsequent siblings in the affected list.
Opening, selecting, resizing, ordinary pair completion and task checkbox toggles
do not normalize existing source numbers.

Tab indents selected items and their children under a preceding sibling;
Shift-Tab moves them back one level. An empty item exits one level per Return,
then exits the list at the top level. Return continues the current list type
and resets a new task checkbox to unchecked. Existing two- and four-space
lists retain their indentation unit; tabs count as two source spaces. Each
operation, including automatic numbering, can be undone together. Task lists remain local Markdown.

List repairs log marker counts (never note content) in the `MarkdownEngine`
subsystem, `lists` category. The maintained core and patch provenance are in
[Vendor/MarkdownEngine](Vendor/MarkdownEngine/README.md).

## Settings and privacy

Left-click the Island Note icon in the macOS menu bar to open the note,
open **Settings…**, or choose **Quit Island Note (⌘Q)**. The menu stays available
while the note is collapsed or another app is active. Quitting flushes pending
edits and keeps the app open if saving fails.

Opening from the menu keeps the note visible through its complete expansion.
Automatic collapse starts only after a new pointer movement outside the note;
stationary input and movements queued before the animation finished are ignored.

The 18-point menu bar template derives from the existing app logo: a filled,
notched sheet with two transparent text lines. The curl merges into the body
at this size. The logo's 60% smooth-corner construction is retained. The body
is 16 points wide, the top notch is 3 points deep, and text cutouts align to
Retina pixels. A single vector path avoids an intermediate SVG mask.
AppKit handles tint, selection and spacing. After changing the
logo, run `python3 scripts/make-status-icon.py` to update the shared SVG resource
used by both SwiftPM and the Xcode target.

Settings also opens from the island or editor's context menu, or with **⌘,**.
The panel retracts while settings or the policy is open so its floating level cannot hide those windows.
The main version is a local scratchpad. Settings contains note-file actions and optional local diagnostics, which are off by default. The status dot reports local saving; clicking it opens Settings unless a local save error needs attention. There is no cloud-sync entry or background synchronization, including on upgrades with a saved Flomo preference.
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

For event-delivery investigations, `bash scripts/package-event-probe.sh` creates a
separate signed Release bundle at `.build/event-probe/IslandNote-Diagnostics.app`.
Its startup self-test verifies the custom application entry point without opening
a note or window. Ordinary builds do not include this probe. Quit the existing
app before running the probe bundle; both use the same note, preferences and signing identity.

With local diagnostics enabled, the probe writes a separate bounded local log,
`IslandNote/Diagnostics/delivery-events.jsonl` under Application Support. It records
gesture type/phase at application, monitor and window dispatch, consumed events,
event age, viewport duration, layout duration and viewport update intervals.
It excludes note text, file names, key events and pointer positions. Sampled values
retain fractional timestamps and event timestamps for cross-stage alignment;
lifecycle events are retained without sampling. Per-stage/type receipt counters
count unsampled events too. Do not compare the number of sampled rows as packet loss.
A handled pinch resizes once in the monitor and continues through native window
dispatch; `handledForwarded` records that decision. Event age measures time since the event timestamp,
not physical gesture-recognition latency; viewport intervals during edge dragging
also include pauses in hand movement. Real gesture delivery requires on-device
reproduction; passing the build and startup self-test does not confirm it.

The main editor panel is constructed as an activating panel. Its scroll view keeps
native text magnification disabled while the original magnify events continue
through AppKit. Font size and native scroll magnification are recorded at dispatch
lifecycle boundaries to detect unintended native zoom.
The `resizeFrame` stage times the full resize update, including the floating
window-origin call (`windowMoveMS`); the narrower `viewport` timer excludes that call.

Add `PROBE_GESTURE_SNAPSHOT=1` to build at `.build/event-probe-native/IslandNote-Diagnostics.app`.
With diagnostics enabled and the note expanded, it adds a read-only native view
snapshot every five seconds: bounded hierarchy paths, runtime classes, recognizer
states and event-delay flags, touch masks, exclusivity and first-responder class.
It never resets or changes a recognizer. These fields contain no note or accessibility text.
The log reports view truncation and per-view recognizer counts (at most 16 states per view).

`PROBE_LAYER_DISPLAY=1` adds a `CATextLayer.display()` timer to the owned status
labels and builds `.build/event-probe-layer/IslandNote-Diagnostics.app`. The
`layerDisplay` stage includes the complete synchronous display call; ordinary
samples are limited to 10 Hz and calls lasting at least 16 ms are retained.
Layer names identify the current/outgoing status label, never its text. Combine
with `PROBE_GESTURE_SNAPSHOT=1` when comparing native gesture state as well.
`PROBE_RESIZE_FIX=1` selects the separate `.build/event-probe-resize-fix` output
for local A/B runs. It changes no runtime behavior. Preserve the original baseline
binary: every rebuild uses current source, including the fixes. Historical
forwarding and activation experiments are described in `docs/diagnostics/pinch-resize.md`.


## Run

Requires macOS 14 or later and Swift 5.9 or later.

```bash
make run
```

`make package` builds a fresh signed `IslandNote.app` without opening it, with an application icon and version metadata. Previous bundles are kept recoverable under the ignored `.build/` directory.

`Resources/AppIcon.svg` is the shared icon source. Run `make icons` to regenerate
the ICNS used by Xcode. Direct packaging and TestFlight packaging generate their
icons from the same SVG automatically; all ten standard macOS icon sizes retain transparency.

## Note file

Settings shows the active note path. **Open Existing File…** selects an existing UTF-8 Markdown or plain-text file. **Change Save Location…** saves a new copy and selects it; the previous file is retained and existing destinations are never overwritten. Pending edits flush before switching. Save conflicts or unreadable selections keep the active file. Each selection starts a separate native editor undo history. Sandboxed builds retain security-scoped bookmarks for user-selected files.

The document limit is **30,000 Unicode scalars**. Oversized edits are rejected as a whole, never truncated. Existing larger files remain readable and can be shortened.

## Personal Flomo version

The local branch `codex/personal-flomo`, starting at `1a2004f`, preserves the complete Flomo-enabled app. It is for personal use and is not pushed or released as part of the main version. To build it without switching this checkout:

```bash
git worktree add ../island-note-personal-flomo codex/personal-flomo
cd ../island-note-personal-flomo
BUILD_NUMBER=2026110201 make package
```

Use one version at a time: both currently use the same app identity and local note directory. Inspect and cherry-pick future editor fixes into the personal branch; do not merge the removal commit into it. Existing Keychain tokens, per-document `flomo-sync.json` records and `Sync Backups/` are left untouched by the main app. Changing the save location no longer moves or pauses old connections; review the selected document before using the personal version again. If only a legacy global `flomo-sync.json` exists without `legacy-sync-document.json`, reopen the original connected note before starting the personal app, so its legacy migration cannot associate that record with a different file. Internal sync code and recovery helpers remain for compatibility, but the main application has no runtime wiring to initialize them. Historical format and sync validation are recorded in [docs/sync-status.md](docs/sync-status.md).

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

For persistent local updates, quit Island Note normally and run `make install-local`.
It uses the signed package, rejects ad-hoc signatures, checks that subsequent
updates match the installed app's designated requirement, and retains a rollback
bundle. Use `make package-dev` only for disposable tests without a saved Flomo
token. If Xcode's command-line shim is unavailable, `SWIFT_BIN` can point to the
installed Command Line Tools Swift executable without changing system settings.

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
The Xcode target uses the same maintained `Vendor/MarkdownEngine` package as local SwiftPM builds.
`ASC_KEY_ID` and `ASC_ISSUER_ID` come from the shell environment; the private key
stays in `~/.appstoreconnect/private_keys/`. Build `3` was previously uploaded. The current release version is `1.0`, with default build `5`. Set `BUILD_NUMBER` to a new increasing integer
for subsequent uploads. An App Store Connect app record
for `local.projects.island-note` must exist before uploading.

This target defines `ISLAND_APP_STORE` and enables App Sandbox without outgoing network access. Selected-file read/write access supports notes and explicit diagnostic exports; app-scoped bookmarks preserve access after relaunch. Notes default to the sandbox container's Application Support directory. Existing unsandboxed notes are selected explicitly through Settings. The privacy manifest declares preferences and elapsed-time API use, with no collected data or tracking.

The same uploaded build is intended for both internal and external testing
(`testFlightInternalTestingOnly` is false). Upload acceptance, build processing,
internal testing and external Beta App Review are separate states: check the
exact uploaded build before reporting availability. The app requires neither an account nor network access. No new store build has been uploaded for the local-only change.
