import Foundation

/// What the parent last asked for, and what the filter has confirmed.
///
/// Roadmap 5.9, #990, stacked on the filter work in #988. The contract is the reviewed one: **accepted is not
/// applied.** A command the daemon has taken is not a claim about the Mac; only a confirmation from the filter,
/// naming the operation and the policy version that carries it, may be read as "done". `desired` is persisted so
/// a restart knows what the parent last asked for — a Mac must not come back paused because a crash froze it.
public struct PauseState: Codable, Equatable {
    public enum Desired: String, Codable, Equatable {
        case paused
        case unpaused
    }

    public static let currentSchema = 1

    public var schemaVersion: Int
    /// The operation counter the daemon assigns. Every operation gets one, and every confirmation names one.
    public var op: Int
    /// The highest operation the filter has confirmed applying.
    public var appliedOp: Int
    public var desired: Desired
    public var updatedAt: Date

    public init(op: Int = 0, appliedOp: Int = 0, desired: Desired = .unpaused, updatedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchema
        self.op = op
        self.appliedOp = appliedOp
        self.desired = desired
        self.updatedAt = Date(timeIntervalSince1970: updatedAt.timeIntervalSince1970.rounded(.down))
    }

    /// True when the parent's last request has been confirmed by the filter.
    public var isApplied: Bool { appliedOp >= op }
}

public struct PauseStateStore {
    public static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/OSRA/pause-state.json")

    public let url: URL
    private let fileManager: FileManager

    public init(url: URL = PauseStateStore.defaultURL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Nil when missing, corrupt or from another schema — the caller then treats the Mac as unpaused, which is
    /// the safe direction: an unreadable state file must never leave a child offline.
    public func read() -> PauseState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? Self.decoder.decode(PauseState.self, from: data),
              state.schemaVersion == PauseState.currentSchema
        else { return nil }
        return state
    }

    /// Atomic and owner-only, like the policy snapshot: a reader never sees half a file, and a Standard user
    /// cannot fake the parent's last request.
    public func write(_ state: PauseState) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        try? fileManager.removeItem(at: temporary)
        try Self.encoder.encode(state).write(to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    public func clear() {
        try? fileManager.removeItem(at: url)
    }
}
