# MarkdownEngine core

This directory contains the core and core tests from
[nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine),
version **0.13.0**, commit `d1421012aeece640e2c2e47e0e573a93cbe2a420`.
The upstream Apache-2.0 license and source notices are retained in `LICENSE`
and the individual files. Optional HighlighterSwift and SwiftMath adapters,
demo applications and media are not included; the core has no dependencies.

## Local changes

`ListStyle.structuredEditing` defaults to `false` and is enabled by Island Note.
It provides a shared source model for sibling numbering and logical depth,
two/four-space and tab indentation, subtree and multi-item movement, gradual
empty-item exit, and source renumbering within the edited list groups. Edits
use native TextKit undo transactions and skip marked-text composition. Fenced
code, including indented and tilde fences, is excluded from list mutations.
Opening a document does not rewrite its source.

The styler and layout fragment use the same depths for bullet glyphs and
24-point nesting (configured by the app). Source whitespace does not add a
second visual indent; bullet marker slots are consistent across `-`, `+`, `*`.
The native view exposes an internal marked-text mutation flag to protect the
first input-method composition update as well as subsequent updates.

The additional implementation lives in `Input/StructuredLists.swift`.
Other modified upstream files:

- `Configuration/MarkdownEditorConfiguration.swift`
- `Input/MarkdownListHandler.swift`
- `TextView/Coordinator/NativeTextViewCoordinator+TextDelegate.swift`
- `TextView/NativeTextView/NativeTextView.swift`
- `Styling/MarkdownASTStyler.swift`
- `Renderer/MarkdownTextLayoutFragment.swift`

`Services/WikiLinkService.swift` also removes an upstream trailing blank line;
its behavior is unchanged.

Run core regressions with `swift test --package-path Vendor/MarkdownEngine`.
`StructuredListsTests` covers the opt-in behavior; the upstream tests cover
the default behavior. App integration tests are `ListEditingTests`.
When updating upstream, rebase these changes and run both test suites.
Do not edit SwiftPM's `.build/checkouts` as a release mechanism.
