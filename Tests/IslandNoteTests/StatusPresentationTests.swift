import XCTest
@testable import IslandNote

final class StatusPresentationTests: XCTestCase {
    private func status(_ local: LocalSaveState, _ phase: SyncPhase, enabled: Bool = true) -> StatusPresentation {
        StatusPresentation(local: local, phase: phase, flomoEnabled: enabled)
    }

    func testSuccessRequiresCurrentLocalVersionToBeSaved() {
        XCTAssertEqual(status(.saved, .synced).tone, .success)
        XCTAssertEqual(status(.saved, .disconnected, enabled: false).tone, .success)
        for local in [LocalSaveState.loading, .saving] {
            XCTAssertEqual(status(local, .synced).tone, .neutral)
            XCTAssertNotEqual(status(local, .synced).summary, SyncPhase.synced.statusSummary)
        }
        for phase in [SyncPhase.waiting, .paused, .disconnected, .offline, .rateLimited, .localChanged] {
            XCTAssertEqual(status(.saved, phase).tone, .neutral)
            XCTAssertNil(status(.saved, phase).caption)
        }
    }

    func testEveryManualIssueStaysExpandedAndSaveFailureWins() {
        for phase in [SyncPhase.conflict, .mergeRequired, .formattingChanged, .unsupported, .tooLong,
                      .connectionFailed, .authorizationRequired, .verifyWrite, .recoverCreate, .failed] {
            XCTAssertEqual(status(.saved, phase).tone, .warning)
            XCTAssertNotNil(status(.saved, phase).caption)
            XCTAssertEqual(status(.saving, phase).tone, .warning)
            XCTAssertEqual(status(.failed("disk error"), phase).tone, .error)
            XCTAssertEqual(status(.failed("disk error"), phase).caption, L10n.tr("Not saved"))
        }
    }

    func testReadOnlyChecksStayCompactButTransfersExpandImmediately() {
        XCTAssertNil(StatusPresentation(local: .saved, phase: .checking, flomoEnabled: true).caption)
        XCTAssertNotNil(StatusPresentation(local: .saved, phase: .syncing, flomoEnabled: true).caption)
        XCTAssertEqual(status(.saving, .syncing).summary, L10n.tr("Saving locally…"))
    }
}
