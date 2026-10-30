import AppKit
import XCTest
@testable import IslandNote

@MainActor
final class ListEditingTests: XCTestCase {
    private func textView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        return view.subviews.compactMap { textView(in: $0) }.first
    }
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    func testNativeListEditPersistsAndRoundTripsThroughTransport() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NoteEditorView(frame: window.contentView!.bounds)
        window.contentView = editor
        editor.string = "1. 父项\n2. 第二项\n  - 子项\n3. 后续"
        editor.setEditingEnabled(true)
        editor.layoutSubtreeIfNeeded()
        settle()
        let tv = try XCTUnwrap(textView(in: editor))
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "第二项").location, length: 0))
        tv.insertText("\t", replacementRange: tv.selectedRange())
        settle()
        let expected = "1. 父项\n  1. 第二项\n    - 子项\n2. 后续"
        XCTAssertEqual(editor.string, expected)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.md")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let store = NoteStore(fileURL: file, configurationDirectory: directory)
        _ = try store.load()
        store.save(editor.string)
        XCTAssertTrue(store.flushSync())
        XCTAssertEqual(try NoteStore(fileURL: file, configurationDirectory: directory).load(), expected)
        XCTAssertNil(SyncDocument.issue(in: expected))
        let transported = SyncDocument.fromFlomo(SyncDocument.toFlomo(expected))
        XCTAssertTrue(SyncDocument.equivalent(local: expected, remote: transported))
        XCTAssertEqual(transported, expected)
    }

    func testListLayoutAtNarrowAndWideWidths() throws {
        _ = NSApplication.shared
        let source = """
        # 列表排版

        1. 设计研究与资料整理
          1. 子项独立编号，长段落应在换行后继续与正文左侧对齐，而不是回到序号下方。
          2. 收集案例与访谈
        2. 验证与交付

        - 实心圆：第一层
          + 空心圆：第二层
            * 方块：第三层
        \t- Tab 缩进同样是第二层
        - [ ] 待办任务与其他列表保持对齐
        - [x] 已完成任务
        """
        for width in [320.0, 520.0] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 650), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let editor = NoteEditorView(frame: window.contentView!.bounds)
            window.contentView = editor
            editor.string = source
            editor.setEditingEnabled(true)
            editor.layoutSubtreeIfNeeded()
            settle()
            let tv = try XCTUnwrap(textView(in: editor))
            tv.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
            settle()
            let layout = try XCTUnwrap(tv.textLayoutManager)
            layout.ensureLayout(for: layout.documentRange)
            XCTAssertLessThanOrEqual(layout.usageBoundsForTextContainer.width, tv.bounds.width + 1)
            if let directory = ProcessInfo.processInfo.environment["ISLAND_NOTE_RENDER_DIR"] {
                editor.wantsLayer = true
                editor.layer?.backgroundColor = NSColor.black.cgColor
                let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
                editor.cacheDisplay(in: editor.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("lists-\(Int(width)).png"))
            }
        }
    }
}
