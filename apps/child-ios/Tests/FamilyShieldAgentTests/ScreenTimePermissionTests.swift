import XCTest
@testable import FamilyShieldAgent

/// 5.5 (#372): the Status screen's Screen Time section, driven through a fake [ScreenTimeAuthorizing] so no
/// test touches FamilyControls. Before this, nothing ever asked for Screen Time (iPhone 13 run, 11 Nov).
@MainActor
final class ScreenTimePermissionTests: XCTestCase {

    func testNotDeterminedShowsTheButton() {
        let row = ScreenTimeRow.of(.notDetermined)
        XCTAssertTrue(row.showsButton)
        XCTAssertEqual(row.value, "Off")
    }

    func testApprovedHidesTheButton() {
        let row = ScreenTimeRow.of(.approved)
        XCTAssertFalse(row.showsButton)
        XCTAssertEqual(row.value, "On")
    }

    func testDeniedShowsTheButtonAndSaysHowToFixItInSettings() {
        let row = ScreenTimeRow.of(.denied)
        XCTAssertTrue(row.showsButton)
        XCTAssertTrue(row.footer.contains("Settings > Screen Time"), row.footer)
    }

    func testAnApprovedRequestHidesTheButtonAndReportsApproved() async {
        let fake = FakeAuthorizer(status: .notDetermined, result: .approve)
        let permission = ScreenTimePermission(authorizer: fake)
        XCTAssertTrue(permission.row.showsButton)
        let approved = await permission.request()
        XCTAssertTrue(approved, "the caller re-runs the rule sync on true")
        XCTAssertEqual(fake.requests, 1)
        XCTAssertEqual(permission.status, .approved)
        XCTAssertFalse(permission.row.showsButton)
        XCTAssertNil(permission.errorMessage)
    }

    func testAThrowingRequestShowsTheErrorAndKeepsTheButton() async {
        let fake = FakeAuthorizer(status: .notDetermined, result: .fail(denyAfter: true))
        let permission = ScreenTimePermission(authorizer: fake)
        let approved = await permission.request()
        XCTAssertFalse(approved)
        XCTAssertEqual(permission.errorMessage, FakeAuthorizer.Refused().localizedDescription)
        XCTAssertEqual(permission.status, .denied)
        XCTAssertTrue(permission.row.showsButton)
    }

    func testAlreadyApprovedNeverPrompts() async {
        let fake = FakeAuthorizer(status: .approved, result: .approve)
        let permission = ScreenTimePermission(authorizer: fake)
        _ = await permission.request()
        XCTAssertEqual(fake.requests, 0)
    }

    func testRefreshRereadsAChangeMadeInSettings() {
        let fake = FakeAuthorizer(status: .approved, result: .approve)
        let permission = ScreenTimePermission(authorizer: fake)
        fake.status = .denied
        XCTAssertEqual(permission.status, .approved, "not re-read until the app is active again")
        permission.refresh()
        XCTAssertEqual(permission.status, .denied)
        XCTAssertTrue(permission.row.showsButton)
    }
}

final class FakeAuthorizer: ScreenTimeAuthorizing {
    enum Result { case approve; case fail(denyAfter: Bool) }
    struct Refused: LocalizedError { var errorDescription: String? { "The request was refused." } }

    var status: ScreenTimeStatus
    let result: Result
    var requests = 0

    init(status: ScreenTimeStatus, result: Result) {
        self.status = status
        self.result = result
    }

    func request() async throws {
        requests += 1
        switch result {
        case .approve: status = .approved
        case .fail(let denyAfter):
            if denyAfter { status = .denied }
            throw Refused()
        }
    }
}
