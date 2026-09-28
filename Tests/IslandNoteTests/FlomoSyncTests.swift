import XCTest
@testable import IslandNote

@MainActor
private final class FakeFlomo: FlomoServing {
    var memo = FlomoMemo(id: "test", content: "Base", updatedAt: "v1")
    var creates = 0
    var updates = 0
    var fetches = 0
    var createError: Error?
    var updateError: Error?
    var fetchError: Error?
    var onFetch: (() -> Void)?
    var onUpdate: (() -> Void)?
    var changeOnWrite = false
    func fetch(id: String) async throws -> FlomoMemo {
        fetches += 1
        onFetch?()
        if let fetchError { throw fetchError }
        return memo
    }
    func create(content: String) async throws -> String {
        creates += 1
        if let createError { throw createError }
        memo = FlomoMemo(id: "test", content: content, updatedAt: "v1")
        return "test"
    }
    func update(id: String, content: String, updatedAt: String) async throws {
        updates += 1
        if let updateError { throw updateError }
        XCTAssertEqual(updatedAt, memo.updatedAt)
        memo = FlomoMemo(id: id, content: changeOnWrite ? "Changed formatting" : content, updatedAt: "v2")
        onUpdate?()
    }
}

@MainActor
final class FlomoSyncTests: XCTestCase {
    private var folders: [URL] = []
    private func make(_ record: SyncRecord = SyncRecord(enabled: true, memoID: "test", baseline: "Base")) throws -> (FlomoSync, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("island-sync-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        let url = folder.appendingPathComponent("sync.json")
        try JSONEncoder().encode(record).write(to: url)
        return (try FlomoSync(stateURL: url), url)
    }

    override func tearDown() {
        // Only unique disposable fixtures created by this test case.
        MainActor.assumeIsolated {
            for folder in folders { try? FileManager.default.removeItem(at: folder) }
            folders = []
        }
        super.tearDown()
    }

    func testLocalPushVerifiesReadbackAndPersistsBaseline() async throws {
        let (sync, url) = try make()
        let client = FakeFlomo()
        sync.readLocal = { "Local change" }
        sync.start(client: client)
        await sync.synchronize()
        XCTAssertEqual(client.updates, 1)
        XCTAssertEqual(sync.record.baseline, "Local change")
        XCTAssertNil(sync.record.pendingWrite)
        XCTAssertEqual(try FlomoSync(stateURL: url).record.baseline, "Local change")
        sync.pause()
    }

    func testRemotePullAndSimultaneousChanges() async throws {
        let (sync, _) = try make()
        let client = FakeFlomo()
        client.memo = FlomoMemo(id: "test", content: "Remote change", updatedAt: "v2")
        var local = "Base"
        sync.readLocal = { local }
        sync.applyRemote = { expected, replacement in
            XCTAssertEqual(expected, local)
            local = replacement
        }
        sync.start(client: client)
        await sync.synchronize()
        XCTAssertEqual(local, "Remote change")
        XCTAssertEqual(client.updates, 0)
        local = "Second local change"
        client.memo = FlomoMemo(id: "test", content: "Second remote change", updatedAt: "v3")
        await sync.synchronize()
        XCTAssertNotNil(sync.conflict)
        XCTAssertEqual(local, "Second local change")
        XCTAssertEqual(client.updates, 0)
        let reviewed = try XCTUnwrap(sync.conflict)
        await sync.synchronize(choice: .remote, reviewed: reviewed)
        XCTAssertEqual(local, "Second remote change")
        sync.pause()
    }

    func testEditWhileFetchingIsNotOverwritten() async throws {
        let (sync, _) = try make()
        let client = FakeFlomo()
        var local = "Base"
        client.memo = FlomoMemo(id: "test", content: "Remote", updatedAt: "v2")
        client.onFetch = { local = "Typing during request" }
        sync.readLocal = { local }
        sync.applyRemote = { _, _ in XCTFail("Must not apply a stale pull") }
        sync.start(client: client)
        await sync.synchronize()
        XCTAssertEqual(local, "Typing during request")
        XCTAssertEqual(sync.record.baseline, "Base")
        sync.pause()
    }

    func testChangedSinceConflictReviewDoesNotOverwrite() async throws {
        let (sync, _) = try make()
        let client = FakeFlomo()
        var local = "Local"
        client.memo = FlomoMemo(id: "test", content: "Remote", updatedAt: "v2")
        sync.readLocal = { local }
        sync.start(client: client)
        await sync.synchronize()
        let reviewed = try XCTUnwrap(sync.conflict)
        local = "Newer local"
        await sync.synchronize(choice: .local, reviewed: reviewed)
        XCTAssertEqual(client.updates, 0)
        XCTAssertEqual(sync.conflict?.local, local)
        sync.pause()
    }

    func testUnknownCreateSurvivesRestartAndCannotBeRetriedByReconnect() async throws {
        let (sync, url) = try make(SyncRecord(enabled: true))
        let client = FakeFlomo()
        client.createError = FlomoClientError.unknownWriteOutcome
        sync.readLocal = { "Local" }
        sync.start(client: client)
        await sync.synchronize()
        XCTAssertEqual(client.creates, 1)
        XCTAssertTrue(sync.record.creationUncertain)
        sync.pause()
        let restarted = try FlomoSync(stateURL: url)
        restarted.readLocal = { "Local" }
        restarted.start(client: client)
        await restarted.connect(client: client, memoID: nil)
        restarted.resume()
        await restarted.synchronize()
        XCTAssertEqual(client.creates, 1)
        restarted.pause()
    }

    func testWriteReadbackDriftDoesNotAdvanceBaseline() async throws {
        let (sync, _) = try make()
        let client = FakeFlomo()
        client.changeOnWrite = true
        sync.readLocal = { "Local" }
        sync.start(client: client)
        await sync.synchronize()
        XCTAssertEqual(sync.record.baseline, "Base")
        XCTAssertEqual(sync.record.pendingWrite, "Local")
        XCTAssertNotNil(sync.conflict)
        await sync.synchronize()
        XCTAssertEqual(client.updates, 1)
        sync.pause()
    }

    func testUnsupportedContentAndIncompleteRemoteNeverWrite() async throws {
        let (sync, _) = try make()
        let client = FakeFlomo()
        var local = "- [ ] Task"
        sync.readLocal = { local }
        sync.start(client: client)
        await sync.synchronize()
        XCTAssertEqual(client.fetches, 0)
        local = "Local"
        client.fetchError = FlomoClientError.incompleteMemo
        await sync.synchronize()
        XCTAssertEqual(client.updates, 0)
        XCTAssertEqual(sync.record.baseline, "Base")
        sync.pause()
    }

    func testDocumentLimitAndUnsupportedSyntax() {
        XCTAssertTrue(SyncDocument.allowsEdit(current: String(repeating: "中", count: 29999), range: NSRange(location: 0, length: 0), replacement: "文"))
        XCTAssertFalse(SyncDocument.allowsEdit(current: String(repeating: "中", count: 30000), range: NSRange(location: 0, length: 0), replacement: "文"))
        XCTAssertTrue(SyncDocument.allowsEdit(current: String(repeating: "x", count: 30001), range: NSRange(location: 0, length: 1), replacement: ""))
        XCTAssertEqual(SyncDocument.count("🏝️"), 2)
        XCTAssertNotNil(SyncDocument.issue(in: "```swift\nlet x = 1\n```"))
        XCTAssertNotNil(SyncDocument.issue(in: "| A | B |\n| --- | --- |\n| 1 | 2 |"))
        XCTAssertNotNil(SyncDocument.issue(in: "- [x] Task"))
        XCTAssertNil(SyncDocument.issue(in: "# Heading\n\n**Bold**\n\n- Item\n  - Nested"))
        XCTAssertEqual(SyncDocument.normalized("\r\n# Header  \r\n\r\n\r\nText\n"), "# Header\n\nText")
    }

    func testHeadingTransportAndLooseListNormalization() {
        let source = "# Heading\n\n## **Nested heading**\n\n- First\n- Second\n  - Child\n\n1. First step\n2. Second step"
        let encoded = SyncDocument.toFlomo(source)
        XCTAssertTrue(encoded.hasPrefix("\\# Heading"))
        let edited = encoded.replacingOccurrences(of: "- First\n- Second\n  - Child", with: "- First\n\n- Second\n\n  - Child")
            .replacingOccurrences(of: "1. First step\n2.", with: "1. First step\n\n2.")
        XCTAssertEqual(SyncDocument.fromFlomo(edited), source)
        XCTAssertEqual(SyncDocument.fromFlomo(SyncDocument.toFlomo(SyncDocument.fromFlomo(edited))), source)
        XCTAssertFalse(SyncDocument.transferFits("# " + String(repeating: "x", count: 29998)))
    }

    func testHardBreaksAreNotSilentlyNormalizedAway() {
        XCTAssertEqual(SyncDocument.normalized("First  \nSecond\n"), "First  \nSecond")
        XCTAssertEqual(SyncDocument.normalized("First    \nSecond"), "First  \nSecond")
        XCTAssertNotNil(SyncDocument.issue(in: "> Quote"))
        XCTAssertNotNil(SyncDocument.issue(in: "[Link](https://example.com)"))
        XCTAssertNil(SyncDocument.issue(in: "- Parent\n  - Child\n    - Grandchild"))
    }

    func testPauseDuringFetchPreventsPull() async throws {
        let (sync, _) = try make()
        let client = FakeFlomo()
        client.memo = FlomoMemo(id: "test", content: "Remote", updatedAt: "v2")
        client.onFetch = { sync.pause() }
        sync.readLocal = { "Base" }
        sync.applyRemote = { _, _ in XCTFail("Paused sync must not pull") }
        sync.start(client: client)
        await sync.synchronize()
        XCTAssertEqual(sync.record.baseline, "Base")
    }

    func testLostUpdateResponseRecoversWithoutAnotherWrite() async throws {
        let (sync, _) = try make()
        let client = FakeFlomo()
        client.updateError = FlomoClientError.unknownWriteOutcome
        sync.readLocal = { "Local" }
        sync.start(client: client)
        await sync.synchronize()
        XCTAssertEqual(sync.record.pendingWrite, "Local")
        client.memo = FlomoMemo(id: "test", content: "Local", updatedAt: "v2")
        await sync.synchronize()
        XCTAssertEqual(client.updates, 1)
        XCTAssertEqual(sync.record.baseline, "Local")
        XCTAssertNil(sync.record.pendingWrite)
        sync.pause()
    }

    func testLocalStoreRefusesExternalChangeDuringPull() throws {
        let (_, stateURL) = try make()
        let url = stateURL.deletingLastPathComponent().appendingPathComponent("note.md")
        try "Base".write(to: url, atomically: true, encoding: .utf8)
        let store = NoteStore(fileURL: url)
        _ = try store.load()
        try "External".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.applySyncedText("Remote", expected: "Base"))
        XCTAssertEqual(try String(contentsOf: url), "External")
    }
}
