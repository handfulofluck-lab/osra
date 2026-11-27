import Foundation

/// The extension's own word on whether it is running, written where the daemon can read it.
///
/// Roadmap 5.9, build step (iii), #988. macOS offers no cross-process query for "is this filter provider
/// running": `NEFilterManager` exposes the *configuration* (`isEnabled`), not the provider's state, and the
/// `SystemExtensions` API submits and replaces extensions rather than reporting them. So the only process that
/// knows writes it down, and the daemon reads it — with a freshness window, because a file left behind by a
/// crashed extension must not read as a running one.
///
/// This is evidence, not proof: a crashed extension that stopped writing goes stale within one window, which
/// is the honest limit of a liveness file and is why the capability report says `degraded` rather than claiming
/// enforcement it cannot see.
public struct FilterLiveness: Codable, Equatable {
    /// Bumped when the file's shape changes; another value is "not mine" and reads as nothing.
    public static let currentSchema = 1

    public var schemaVersion: Int
    /// False is written on a clean stop, so a deliberate stop is not mistaken for a crash.
    public var running: Bool
    /// The extension's own clock. The daemon compares it with its own, so a badly-skewed extension clock reads
    /// as stale rather than as fresh — the failure direction that under-claims.
    public var updatedAt: Date

    public init(running: Bool, updatedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchema
        self.running = running
        self.updatedAt = Self.wholeSeconds(updatedAt)
    }

    /// Seconds only, like the policy snapshot: the file stores ISO-8601 and the value must compare equal to
    /// what is read back.
    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

public struct FilterLivenessStore {
    public static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/OSRA/filter-status.json")

    public let url: URL
    private let fileManager: FileManager

    public init(url: URL = FilterLivenessStore.defaultURL, fileManager: FileManager = .default) {
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

    /// Nil when the file is missing, corrupt, from another schema, or not ours to trust.
    public func read() -> FilterLiveness? {
        guard let data = try? Data(contentsOf: url),
              let liveness = try? Self.decoder.decode(FilterLiveness.self, from: data),
              liveness.schemaVersion == FilterLiveness.currentSchema
        else { return nil }
        return liveness
    }

    /// Atomic and `0600` for the same reason as the policy snapshot: a reader must never see half a file, and a
    /// Standard user must not be able to fake "the filter is running" — or to stop it looking like it is.
    public func write(_ liveness: FilterLiveness) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])

        let temporary = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        try? fileManager.removeItem(at: temporary)
        try Self.encoder.encode(liveness).write(to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}
