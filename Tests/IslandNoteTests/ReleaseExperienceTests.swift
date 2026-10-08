import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class ReleaseExperienceTests: XCTestCase {
    func testFlomoPreferencePersistsWithoutLanguageOverride() throws {
        let suite = "island-preferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("zh-Hans", forKey: "appLanguage")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.flomoEnabled)
        preferences.setFlomoEnabled(true)
        let reopened = AppPreferences(defaults: defaults)
        XCTAssertTrue(reopened.flomoEnabled)
        reopened.setFlomoEnabled(false)
        XCTAssertFalse(AppPreferences(defaults: defaults).flomoEnabled)
        XCTAssertFalse(defaults.bool(forKey: InteractionDiagnostics.preferenceKey))
    }

    func testLegacyFlomoConnectionRestoresExtensionWithoutOverridingExplicitOff() throws {
        let suite = "island-migration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(SyncRecord(enabled: false, memoID: "previous")).write(to: url)
        XCTAssertTrue(AppPreferences(defaults: defaults, legacyStateURL: url).flomoEnabled)
        defaults.set(false, forKey: AppPreferences.flomoKey)
        XCTAssertFalse(AppPreferences(defaults: defaults, legacyStateURL: url).flomoEnabled)
    }

    func testSwitchingFilesCannotUndoOldEditsIntoNewDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("island-undo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md"), second = directory.appendingPathComponent("second.md")
        try "Alpha".write(to: first, atomically: true, encoding: .utf8)
        try "Beta stays intact".write(to: second, atomically: true, encoding: .utf8)
        let store = NoteStore(fileURL: first, configurationDirectory: directory)
        let editor = NoteEditorView(frame: NSRect(x: 0, y: 0, width: 460, height: 275))
        let window = NSPanel(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        defer { window.close() }
        editor.string = try store.load()
        editor.onTextChanged = { store.save($0) }
        editor.setEditingEnabled(true)
        window.makeKeyAndOrderFront(nil)
        func findText(_ view: NSView) -> NSTextView? { (view as? NSTextView) ?? view.subviews.compactMap(findText).first }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let oldEditor = try XCTUnwrap(findText(editor))
        oldEditor.insertText(" change", replacementRange: NSRange(location: oldEditor.string.utf16.count, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(editor.string, "Alpha change")
        XCTAssertTrue(store.flushSync())
        let oldUndo = try XCTUnwrap(oldEditor.undoManager)
        XCTAssertTrue(oldUndo.canUndo)
        editor.openDocument(try store.openExisting(second))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let newEditor = try XCTUnwrap(findText(editor))
        XCTAssertFalse(oldEditor === newEditor)
        XCTAssertFalse(newEditor.undoManager?.canUndo ?? true)
        // Even a delayed action still referencing the old native editor is ignored.
        oldUndo.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        editor.flushPending()
        XCTAssertTrue(store.flushSync())
        XCTAssertEqual(editor.string, "Beta stays intact")
        XCTAssertEqual(try String(contentsOf: second), "Beta stays intact")
        XCTAssertEqual(try String(contentsOf: first), "Alpha change")
    }

    func testBothLanguagesIncludePolicyAndNestedMenuTranslations() throws {
        let original = L10n.language
        defer { L10n.language = original }
        for language in [AppLanguage.english, .chinese] {
            L10n.language = language
            let policy = try String(contentsOf: XCTUnwrap(L10n.resource("Privacy", extension: "html")), encoding: .utf8)
            XCTAssertTrue(policy.contains("https://help.flomoapp.com/privacy.html"))
            XCTAssertTrue(policy.contains("300"))
            XCTAssertTrue(policy.contains(language == .chinese ? "本机笔记" : "Local notes"))
            XCTAssertFalse(policy.contains("<script"))
            let menu = NSMenu()
            menu.addItem(withTitle: "Bold", action: nil, keyEquivalent: "")
            let parent = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: "")
            let child = NSMenu(); child.addItem(withTitle: "Privacy Policy", action: nil, keyEquivalent: "")
            parent.submenu = child; menu.addItem(parent)
            NoteEditorView.localizeMenu(menu)
            XCTAssertEqual(menu.items[0].title, language == .chinese ? "粗体" : "Bold")
            XCTAssertEqual(child.items[0].title, language == .chinese ? "隐私政策" : "Privacy Policy")
            XCTAssertEqual(L10n.tr("Write something…"), language == .chinese ? "写点什么…" : "Write something…")
        }
    }

    func testLanguageChangeKeepsEditorTextSelectionAndUndo() throws {
        let original = L10n.language
        defer { L10n.language = original }
        let editor = NoteEditorView(frame: NSRect(x: 0, y: 0, width: 460, height: 275))
        let window = NSPanel(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        defer { window.close() }
        editor.string = "# 中文标题\n\nKeep this note unchanged."
        editor.setEditingEnabled(true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        func findText(_ view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.compactMap(findText).first
        }
        let text = try XCTUnwrap(findText(editor))
        text.setSelectedRange(NSRange(location: 3, length: 4))
        let selection = text.selectedRange(), undo = text.undoManager
        L10n.language = .chinese
        editor.refreshLocalizedUI()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        XCTAssertEqual(editor.string, "# 中文标题\n\nKeep this note unchanged.")
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertTrue(text.undoManager === undo)
    }

    func testSettingsControlsFitBothLanguagesAndFlomoStartsDisabled() throws {
        let original = L10n.language
        defer { L10n.language = original }
        for language in [AppLanguage.english, .chinese] {
            L10n.language = language
            let preferences = AppPreferences(defaults: nil)
            let diagnostics = InteractionDiagnostics(defaults: nil, enabled: false)
            let controller = SettingsWindowController(preferences: preferences, diagnostics: diagnostics, appVersion: "1.0")
            controller.notePath = "/Users/example/Documents/Miles-Vault/Daily notes/Island Note.md"
            controller.rebuild()
            let window = try XCTUnwrap(controller.window)
            window.appearance = NSAppearance(named: .aqua)
            controller.showWindow(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let root = try XCTUnwrap(window.contentView)
            root.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let views = descendants(root)
            XCTAssertFalse(views.contains { $0 is NSPopUpButton })
            let flomo = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "settings.flomo" })
            XCTAssertEqual(flomo.state, .off)
            XCTAssertFalse(views.compactMap { $0 as? NSButton }.first { $0.title == L10n.tr("Configure Flomo…") }?.isEnabled ?? true)
            for view in views where view is NSButton || view is NSTextField || view is NSPopUpButton {
                XCTAssertGreaterThan(view.bounds.width, 0)
                XCTAssertGreaterThan(view.bounds.height, 0)
                let frame = view.convert(view.bounds, to: root)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.1)
                XCTAssertGreaterThanOrEqual(frame.minY, -0.1)
                XCTAssertLessThanOrEqual(frame.maxX, root.bounds.maxX + 0.1)
                XCTAssertLessThanOrEqual(frame.maxY, root.bounds.maxY + 0.1)
            }
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/release-ux-qa")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings-" + language.rawValue + ".png"))
            }
            preferences.setFlomoEnabled(true)
            controller.rebuild()
            window.appearance = NSAppearance(named: .darkAqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings-" + language.rawValue + "-dark.png"))
            }
            window.close()
        }
    }

    func testSettingsSwitchAcceptsAndRejectsChangesWithoutReplacingFocusedControls() throws {
        let preferences = AppPreferences(defaults: nil)
        let controller = SettingsWindowController(preferences: preferences,
            diagnostics: InteractionDiagnostics(defaults: nil, enabled: false))
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(root).compactMap { $0 as? NSButton }
        let flomo = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "settings.flomo" })
        let configure = try XCTUnwrap(buttons.first { $0.title == L10n.tr("Configure Flomo…") })
        window.makeFirstResponder(flomo)
        let initialFrame = window.frame
        controller.onFlomoToggle = { preferences.setFlomoEnabled($0); return true }
        flomo.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(preferences.flomoEnabled)
        XCTAssertEqual(flomo.state, .on)
        XCTAssertTrue(configure.isEnabled)
        XCTAssertTrue(window.firstResponder === flomo)
        let thumb = try XCTUnwrap(flomo.layer?.sublayers?.first?.sublayers?.first)
        XCTAssertEqual(thumb.position.x, 31, "The native action must update the drawn switch as well as its state.")
        controller.onFlomoToggle = { _ in false }
        flomo.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(flomo.state, .on)
        XCTAssertTrue(configure.isEnabled)
        XCTAssertEqual(thumb.position.x, 31)
        controller.onFlomoToggle = { preferences.setFlomoEnabled($0); return true }
        flomo.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(flomo.state, .off)
        XCTAssertFalse(configure.isEnabled)
        XCTAssertEqual(thumb.position.x, 13)
        XCTAssertTrue(window.contentView === root)
        XCTAssertEqual(window.frame, initialFrame)
    }

    func testClearingDiagnosticsDeletesOnlyItsRecordsAndKeepsOptInState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("island-clear-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = InteractionDiagnostics(directory: directory, defaults: nil, enabled: true)
        let state = InteractionDiagnosticState(mode: "expanded", floating: false, dragging: false,
            docking: false, edgeResizing: false, animating: false, panelKey: true, appActive: true,
            reduceMotion: false, width: 460, height: 275, targetWidth: nil, targetHeight: nil,
            screenWidth: 1400, screenHeight: 900)
        diagnostics.record(.checkpoint, state: state)
        diagnostics.flush()
        let keep = directory.appendingPathComponent("keep.txt")
        try "user file".write(to: keep, atomically: true, encoding: .utf8)
        diagnostics.clear()
        XCTAssertTrue(diagnostics.isEnabled)
        XCTAssertTrue(diagnostics.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.jsonl").path))
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "user file")
        diagnostics.record(.checkpoint, state: state)
        diagnostics.flush()
        XCTAssertEqual(diagnostics.events.count, 1)
    }
}
