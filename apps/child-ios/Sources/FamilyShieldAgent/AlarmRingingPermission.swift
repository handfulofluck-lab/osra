import Combine
import Foundation

/// Ringing permission on the child phone (#880). iOS asks "allow OSRA Kids to schedule alarms and timers" the
/// first time a ring arrives; a child who closes that prompt gets `alarm_permission_denied` and **nothing sounds**,
/// while the parent believes the phone is ringing.
///
/// So the prompt is asked at setup, in words the child can act on, and a denial leaves a row that says what is
/// wrong and how to fix it. The status is read through [AlarmRingingAuthorizing] so all three states are testable
/// without AlarmKit; the real one is `AlarmKitRingingAuthorizer` in `AlarmKitRingBackend.swift`.
///
/// Wording is the Arabic Language Bureau's (`604` `7122208660`); the English is the UI/UX Bureau's `#880` draft plus
/// the button label the Bureau wrote because the spec had none.
public enum AlarmRingingStatus: Equatable {
    case notDetermined
    case approved
    case denied
}

public protocol AlarmRingingAuthorizing: AnyObject {
    /// False on a phone that cannot ring at all (no AlarmKit); the row then says nothing rather than blaming the
    /// child for a build fact.
    var available: Bool { get }
    var status: AlarmRingingStatus { get }
    /// Shows the AlarmKit prompt; returns the status afterwards.
    func request() async -> AlarmRingingStatus
}

/// What the status row shows, and which button it offers.
public struct AlarmRingingRow: Equatable {
    public enum Action: Equatable {
        /// Ask now: the setup step, or the row on a phone that has not been asked.
        case ask
        /// The permission was refused; the only honest fix is Settings, so the button goes there.
        case openSettings
    }

    public let body: String
    public let buttonTitle: String
    public let action: Action

    /// One row per state that has something to say. `approved` and an unsupported phone have none.
    public static func of(_ status: AlarmRingingStatus, available: Bool = true) -> AlarmRingingRow? {
        guard available else { return nil }
        switch status {
        case .notDetermined:
            return AlarmRingingRow(body: L10n.tr("alarm_setup_body"),
                                   buttonTitle: L10n.tr("alarm_setup_button"),
                                   action: .ask)
        case .denied:
            return AlarmRingingRow(body: L10n.tr("alarm_denied_row"),
                                   buttonTitle: L10n.tr("alarm_denied_button"),
                                   action: .openSettings)
        case .approved:
            return nil
        }
    }
}

/// A closure-backed conformer, so every state is testable without AlarmKit and the real one is one line.
public final class AlarmRingingAuthorizer: AlarmRingingAuthorizing {
    public let available: Bool
    private let read: () -> AlarmRingingStatus
    private let ask: () async -> Bool

    public init(available: Bool = true,
                read: @escaping () -> AlarmRingingStatus,
                ask: @escaping () async -> Bool) {
        self.available = available
        self.read = read
        self.ask = ask
    }

    public var status: AlarmRingingStatus { read() }

    public func request() async -> AlarmRingingStatus {
        _ = await ask()
        return read()
    }
}

/// The section's state, mirroring `ScreenTimePermission`: the status and the last request's outcome.@MainActor
public final class AlarmRingingPermission: ObservableObject {
    @Published public private(set) var status: AlarmRingingStatus
    @Published public private(set) var errorMessage: String?

    private let authorizer: AlarmRingingAuthorizing

    public init(authorizer: AlarmRingingAuthorizing) {
        self.authorizer = authorizer
        self.status = authorizer.status
    }

    public var available: Bool { authorizer.available }
    public var row: AlarmRingingRow? { .of(status, available: authorizer.available) }

    /// Re-reads the status. The child may have changed the permission in Settings while the app was in the
    /// background, so the screen calls this on every return to the foreground (same rule as Location).
    public func refresh() {
        status = authorizer.status
    }

    @discardableResult
    public func request() async -> Bool {
        let next = await authorizer.request()
        status = next
        errorMessage = next == .approved ? nil : L10n.tr("alarm_denied_row")
        return next == .approved
    }
}
