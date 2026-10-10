import XCTest
@testable import IslandNote

final class StatusPresentationTests: XCTestCase {
    private func status(_ local: LocalSaveState, _ phase: SyncPhase, enabled: Bool = true, hovered: Bool = false) -> StatusPresentation {
        StatusPresentation(local: local, phase: phase, flomoEnabled: enabled, hovered: hovered, checkingExpanded: true)
    }

    func testSuccessRequiresCurrentLocalVersionToBeSaved() {
        XCTAssertEqual(status(.saved, .synced).tone, .success)
        XCTAssertEqual(status(.saved, .disconnected, enabled: false).tone, .success)
        for local in [LocalSaveState.loading, .saving] {
            XCTAssertEqual(status(local, .synced).tone, .neutral)
            XCTAssertNotEqual(status(local, .synced, hovered: true).summary, SyncPhase.synced.hoverSummary)
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

    func testShortChecksWaitButUploadsExpandImmediately() {
        XCTAssertNil(StatusPresentation(local: .saved, phase: .checking, flomoEnabled: true,
                                        hovered: false, checkingExpanded: false).caption)
        XCTAssertNotNil(StatusPresentation(local: .saved, phase: .syncing, flomoEnabled: true,
                                           hovered: false, checkingExpanded: false).caption)
        XCTAssertEqual(status(.saving, .syncing, hovered: true).summary, L10n.tr("Saving locally…"))
    }
}
