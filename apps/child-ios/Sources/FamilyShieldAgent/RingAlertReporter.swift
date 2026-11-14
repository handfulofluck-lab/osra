import Foundation

@MainActor
public protocol RingAlertReporting {
    func report(state: RingEventState, ringId: UUID, dismissalCount: Int) async -> Bool
}

@MainActor
public struct RingAlertReporter: RingAlertReporting {
    typealias Sender = (URLRequest) async throws -> (status: Int, body: Data)
    public static let deliveredKey = "ring.deliveredDedupeKeys"
    private let defaults: UserDefaults?
    private let reporter: AlertReporter
    private let sender: Sender

    init(defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName),
         reporter: AlertReporter? = nil,
         sender: @escaping Sender = { try await AlertReporter.send($0) }) {
        self.defaults = defaults
        self.reporter = reporter ?? AlertReporter(hmacSecret: AlertReporter.pairedHmacSecret())
        self.sender = sender
    }

    public func report(state: RingEventState, ringId: UUID, dismissalCount: Int) async -> Bool {
        let key = RingPolicy.dedupeKey(for: state, ringId: ringId, dismissalCount: dismissalCount)
        let delivered = Set(defaults?.stringArray(forKey: Self.deliveredKey) ?? [])
        guard !delivered.contains(key) else { return true }
        let metadata: [String: Any] = ["state": state.rawValue, "ringId": ringId.uuidString]
        guard let request = reporter.makeRequest(
            category: "ring", severity: state == .childDismissed ? "warning" : "info",
            title: "Phone ring", body: Self.fallback(state, dismissalCount: dismissalCount),
            childId: AlertReporter.pairedChildId(), metadata: metadata, dedupeKey: key) else { return false }
        do {
            let response = try await sender(request)
            guard response.status == 200 || response.status == 201 else { return false }
            defaults?.set(delivered.union([key]).sorted(), forKey: Self.deliveredKey)
            return true
        } catch {
            return false
        }
    }

    public static func clear() {
        UserDefaults(suiteName: AgentIdentityStore.suiteName)?.removeObject(forKey: deliveredKey)
    }

    private static func fallback(_ state: RingEventState, dismissalCount: Int) -> String {
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
