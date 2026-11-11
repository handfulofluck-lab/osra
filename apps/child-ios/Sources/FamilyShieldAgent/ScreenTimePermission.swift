import Combine
import Foundation

/// Screen Time authorization on the child phone (5.5, #372). Before this, `requestAuthorization()` had no
/// caller, so the FamilyControls prompt never appeared and every shield stopped at "no Screen Time
/// authorization": nothing a parent set was enforced on iOS (iPhone 13 run, 11 Nov).
///
/// The status is read through [ScreenTimeAuthorizing], so the tests drive all three states without
/// FamilyControls; the real one is `FamilyControlsAuthorizer` in `ScreenTimeController.swift`.
public enum ScreenTimeStatus: Equatable {
    case notDetermined
    case approved
    case denied
}

public protocol ScreenTimeAuthorizing: AnyObject {
    var status: ScreenTimeStatus { get }
    /// Shows the FamilyControls `.child` prompt; throws when it is refused or cannot be shown.
    func request() async throws
}

/// What the Status screen's "Screen Time" section shows for a status.
public struct ScreenTimeRow: Equatable {
    public let value: String
    public let showsButton: Bool
    public let footer: String

    public static let buttonTitle = "Turn on Screen Time"

    public static func of(_ status: ScreenTimeStatus) -> ScreenTimeRow {
        switch status {
        case .notDetermined:
            return ScreenTimeRow(value: "Off", showsButton: true,
                                 footer: "Your parents' app limits and blocks need Screen Time. Tap \"\(buttonTitle)\" and allow it.")
        case .approved:
            return ScreenTimeRow(value: "On", showsButton: false,
                                 footer: "Your parents' app limits and blocks are applied on this device.")
        case .denied:
            return ScreenTimeRow(value: "Not allowed", showsButton: true,
                                 footer: "Screen Time was not allowed, so your parents' limits are not applied. Tap \"\(buttonTitle)\" again, or ask a parent to open Settings > Screen Time and allow OSRA Kids.")
        }
    }
}

/// The section's state: the status, and the error text of a failed request. The view re-reads the status
/// when the app returns to the foreground, as it does for Location.
@MainActor
public final class ScreenTimePermission: ObservableObject {
    @Published public private(set) var status: ScreenTimeStatus
    @Published public private(set) var errorMessage: String?

    private let authorizer: ScreenTimeAuthorizing

    public init(authorizer: ScreenTimeAuthorizing) {
        self.authorizer = authorizer
        self.status = authorizer.status
    }

    public var row: ScreenTimeRow { .of(status) }

    public func refresh() {
        status = authorizer.status
    }

    /// Asks only while not approved. Returns true when the request ended approved, so the caller can
    /// re-run the rule sync and apply the parent's rules at once.
    @discardableResult
    public func request() async -> Bool {
        guard status != .approved else { return true }
        do {
            try await authorizer.request()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
        return status == .approved
    }
}
