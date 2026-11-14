import XCTest
@testable import KarenApp

@MainActor
final class RemoteApprovalSettingsTests: XCTestCase {

    func testRequestOpenSettingsSetsPendingAndDoesNotOpenImmediately() {
        let karen = KarenCore()
        XCTAssertFalse(karen.showSettings)
        XCTAssertFalse(karen.isRemoteApprovalPending)

        karen.requestOpenSettings()

        // Crucial security invariant: Settings must NOT open immediately before receiving approval!
        XCTAssertFalse(karen.showSettings, "Settings must not open synchronously before remote approval is received")
        XCTAssertTrue(karen.isRemoteApprovalPending, "Remote approval must be marked as pending")
    }

    func testDuplicateRequestOpenSettingsDoesNotDuplicate() {
        let karen = KarenCore()
        karen.requestOpenSettings()
        XCTAssertTrue(karen.isRemoteApprovalPending)

        // Second call while pending
        karen.requestOpenSettings()
        XCTAssertTrue(karen.isRemoteApprovalPending)
        XCTAssertFalse(karen.showSettings)
    }

    func testSettingsAlreadyOpenDoesNothing() {
        let karen = KarenCore()
        karen.showSettings = true
        karen.requestOpenSettings()
        XCTAssertFalse(karen.isRemoteApprovalPending, "Should not request approval if Settings is already open")
    }
}
