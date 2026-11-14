import Foundation

public enum RingReportOutcome: Equatable {
    case delivered
    case pending
    case resume(after: Int)
}

public struct RingPendingEvent: Codable, Equatable {
    public let state: RingEventState
    public let ringId: UUID
    public let dismissalCount: Int
    public let afterRestart: Bool

    public init(state: RingEventState, ringId: UUID, dismissalCount: Int, afterRestart: Bool) {
        self.state = state
        self.ringId = ringId
        self.dismissalCount = dismissalCount
        self.afterRestart = afterRestart
    }

    var dedupeKey: String {
        RingPolicy.dedupeKey(for: state, ringId: ringId, dismissalCount: dismissalCount)
    }
}

@MainActor
public protocol RingAlertReporting {
    func report(state: RingEventState, ringId: UUID, dismissalCount: Int,
                afterRestart: Bool) async -> RingReportOutcome
    func pendingEvents() -> [RingPendingEvent]
}

public extension RingAlertReporting {
    func report(state: RingEventState, ringId: UUID, dismissalCount: Int) async -> RingReportOutcome {
        await report(state: state, ringId: ringId, dismissalCount: dismissalCount, afterRestart: false)
    }
    func pendingEvents() -> [RingPendingEvent] { [] }
}

@MainActor
public struct RingAlertReporter: RingAlertReporting {
    typealias Sender = (URLRequest) async throws -> (status: Int, body: Data)
    public static let deliveredKey = "ring.deliveredDedupeKeys"
    public static let pendingKey = "ring.pendingEvents"
    private let defaults: UserDefaults?
    private let suppliedReporter: AlertReporter?
    private let sender: Sender
    private var currentReporter: AlertReporter {
        suppliedReporter ?? AlertReporter(hmacSecret: AlertReporter.pairedHmacSecret())
    }

    init(defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName),
         reporter: AlertReporter? = nil,
         sender: @escaping Sender = { try await AlertReporter.send($0) }) {
        self.defaults = defaults
        self.suppliedReporter = reporter
        self.sender = sender
    }

    public func pendingEvents() -> [RingPendingEvent] {
        (defaults?.array(forKey: Self.pendingKey) as? [Data] ?? []).compactMap {
            try? JSONDecoder().decode(RingPendingEvent.self, from: $0)
        }
    }

    public func report(state: RingEventState, ringId: UUID, dismissalCount: Int,
                       afterRestart: Bool = false) async -> RingReportOutcome {
        let event = RingPendingEvent(state: state, ringId: ringId, dismissalCount: dismissalCount, afterRestart: afterRestart)
        let key = event.dedupeKey
        let delivered = Set(defaults?.stringArray(forKey: Self.deliveredKey) ?? [])
        if delivered.contains(key) {
            removePending(key)
            return .delivered
        }
        recordPending(event)
        var metadata: [String: Any] = ["state": state.rawValue, "ringId": ringId.uuidString.lowercased()]
        if afterRestart { metadata["afterRestart"] = true }
        guard let request = currentReporter.makeRequest(
            category: "ring", severity: state == .childDismissed ? "warning" : "info",
            title: "Phone ring", body: Self.fallback(state, dismissalCount: dismissalCount, afterRestart: afterRestart),
            childId: AlertReporter.pairedChildId(), metadata: metadata, dedupeKey: key) else { return .pending }
        do {
            let response = try await sender(request)
            guard response.status == 200 || response.status == 201 else { return .pending }
            let payload = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            if payload?["active"] as? Bool == true {
                guard state == .timedOut, afterRestart,
                      let seconds = payload?["retryAfterSeconds"] as? Int, seconds > 0, seconds <= 300
                else { return .pending }
                return .resume(after: seconds)
            }
            removePending(key)
            defaults?.set(delivered.union([key]).sorted(), forKey: Self.deliveredKey)
            return .delivered
        } catch {
            return .pending
        }
    }

    public static func clear() {
        let defaults = UserDefaults(suiteName: AgentIdentityStore.suiteName)
        defaults?.removeObject(forKey: deliveredKey)
        defaults?.removeObject(forKey: pendingKey)
    }

    private func recordPending(_ event: RingPendingEvent) {
        var events = pendingEvents()
        guard !events.contains(event) else { return }
        events.append(event)
        defaults?.set(events.map { try? JSONEncoder().encode($0) }, forKey: Self.pendingKey)
    }

    private func removePending(_ key: String) {
        let remaining = pendingEvents().filter { $0.dedupeKey != key }
        defaults?.set(remaining.map { try? JSONEncoder().encode($0) }, forKey: Self.pendingKey)
    }

    private static func fallback(_ state: RingEventState, dismissalCount: Int, afterRestart: Bool) -> String {
        if state == .timedOut && afterRestart { return "The ring ended after the phone was restarted." }
        switch state {
        case .childDismissed where dismissalCount == 1:
            return "The ring alert was dismissed on the phone. It is ringing again."
        case .childDismissed:
            return "The ring alert was dismissed on the phone \(dismissalCount) times. It is still ringing."
        case .pinStopped:
            return "The ring was stopped on the phone with the parent PIN."
        case .parentStopped:
            return "A parent stopped the ring from the OSRA app."
        case .timedOut:
            return "The ring ended by itself after 5 minutes."
        }
    }
}
