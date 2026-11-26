import Foundation

/// #1046: the app group is the only way the report extension and the agent can meet. The extension writes one
/// `UsageSnapshot` per day; the agent reads it and uploads it on the telemetry it already sends. Same shape and same
/// failure policy as `AppGroupStore`: a key that cannot be read is *nil*, never an empty day, because "unreadable"
/// and "no use" are different sentences to a parent.
public struct UsageStore {
    public static var key: String { UsageSnapshot.appGroupKey }

    let defaults: UserDefaults?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) {
        self.defaults = defaults
    }

    /// The last snapshot written by the extension, or nil when there is none or it cannot be decoded.
    public func load() -> UsageSnapshot? {
        guard let defaults, let data = defaults.data(forKey: Self.key) else { return nil }
        return try? PropertyListDecoder().decode(UsageSnapshot.self, from: data)
    }

    /// Write one day, replacing whatever was there. Used by the extension; returns whether it stuck, so the caller
    /// can log a failed write instead of believing it.
    @discardableResult
    public func save(_ snapshot: UsageSnapshot) -> Bool {
        guard let defaults, let data = try? PropertyListEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }

    /// Called by the agent once a day has been uploaded, so the same hours are not sent twice. The extension writes
    /// a fresh snapshot the next time the report runs.
    public func clear() {
        defaults?.removeObject(forKey: Self.key)
    }
}
