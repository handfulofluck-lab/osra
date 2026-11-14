import Foundation

@MainActor
public protocol RingBackend {
    var available: Bool { get }
    func requestAuthorization() async -> Bool
    func schedule(_ id: UUID) async throws
    func stop(_ id: UUID) async throws
    func scheduledIDs() async -> Set<UUID>
    func updates() async -> AsyncStream<Set<UUID>>
}

public protocol RingStore {
    func load() -> RingState?
    func save(_ state: RingState?)
}

public protocol RingHistory {
    func contains(_ id: UUID) -> Bool
    func record(_ id: UUID)
    func remove(_ id: UUID)
}

public struct UserDefaultsRingHistory: RingHistory {
    public static let key = "ring.stoppedCommandIds"
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) {
        self.defaults = defaults
    }

    public func contains(_ id: UUID) -> Bool {
        defaults?.stringArray(forKey: Self.key)?.contains(id.uuidString) == true
    }

    public func record(_ id: UUID) {
        var ids = Set(defaults?.stringArray(forKey: Self.key) ?? [])
        ids.insert(id.uuidString)
        defaults?.set(ids.sorted(), forKey: Self.key)
    }

    public func remove(_ id: UUID) {
        var ids = Set(defaults?.stringArray(forKey: Self.key) ?? [])
        ids.remove(id.uuidString)
        defaults?.set(ids.sorted(), forKey: Self.key)
    }

    public static func clear() {
        UserDefaults(suiteName: AgentIdentityStore.suiteName)?.removeObject(forKey: key)
    }
}

public final class UserDefaultsRingStore: RingStore {
    public static let key = "ring.state"
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) {
        self.defaults = defaults
    }

    public func load() -> RingState? {
        guard let data = defaults?.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(RingState.self, from: data)
    }

    public func save(_ state: RingState?) {
        if let state {
            defaults?.set(try? JSONEncoder().encode(state), forKey: Self.key)
        } else {
            defaults?.removeObject(forKey: Self.key)
        }
    }
}

public enum RingCommandError: String, Error, Equatable {
    case invalidCommand = "invalid_command"
    case unsupportedOS = "unsupported_os"
    case authorizationDenied = "alarm_permission_denied"
    case scheduleFailed = "schedule_failed"
}
