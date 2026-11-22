import Foundation

/// The handoff from the daemon to the content-filter extension: one small JSON file, written atomically by
/// the root daemon and read by the extension.
///
/// Roadmap 5.9, build step (iii), ADR-0036. Codex chose this shape on #988: a local policy snapshot rather
/// than an XPC listener, because it survives an extension restart with no extra process, and it has one
/// writer by construction. The file is not a secret — it is the family's rules, which the parent already
/// set — but it says what a child cannot visit, so a Standard user must not be able to edit it.
///
/// Three properties, each with a test that fails without it:
///  * **Atomic.** The daemon writes a temporary file beside the real one and renames it into place, so a
///    reader either sees the whole previous version or the whole new one, never a mixture, and a crash
///    mid-write leaves the previous version readable.
///  * **Only the writer can replace it.** The store refuses to replace a file whose mode is not `0600`, and
///    when an expected owner is set (root, in the daemon) it refuses a file owned by anyone else.
///  * **Monotonic.** A snapshot with a lower `version` than the file it would replace is refused, so a
///    stale daemon cannot roll the filter back to older rules.
public struct PolicySnapshot: Codable, Equatable {
    /// Bumped when the file's shape changes in a way an older reader cannot read. The reader treats any other
    /// value as "not mine" and returns nothing rather than guessing at the fields.
    public static let currentSchema = 1

    public var schemaVersion: Int
    /// The daemon's own counter: it rises with every write, whatever the server's rules version does.
    public var version: Int
    /// The server's rules version this policy came from (`RuleSet.effectiveRulesVersion`), for the log line.
    public var rulesVersion: Int
    public var writtenAt: Date
    public var policy: FilterPolicy

    public init(version: Int, rulesVersion: Int, policy: FilterPolicy, writtenAt: Date = Date()) {
        self.schemaVersion = Self.currentSchema
        self.version = version
        self.rulesVersion = rulesVersion
        self.writtenAt = writtenAt
        self.policy = policy
    }
}

public struct PolicySnapshotStore {
    public enum StoreError: Error, Equatable {
        /// The file is there but not ours to replace: mode is not `0600`.
        case unsafeFileMode(Int)
        /// The file is ours by mode but belongs to another account.
        case unsafeOwner(Int)
        case staleVersion(current: Int, incoming: Int)
    }

    /// Root's Application Support: `/Library`, not `~/Library`, so one policy serves every account on the Mac.
    public static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/OSRA/filter-policy.json")

    public let url: URL
    /// The account allowed to replace the file: 0 (root) in the daemon. `nil` skips the check, which is what
    /// the tests use, because a test runner is not root.
    public let expectedOwner: Int?

    private let fileManager: FileManager

    public init(url: URL = PolicySnapshotStore.defaultURL,
                expectedOwner: Int? = 0,
                fileManager: FileManager = .default) {
        self.url = url
        self.expectedOwner = expectedOwner
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

    /// The whole snapshot, or nil when it is missing, unreadable, corrupt or written by a newer schema.
    /// A nil here is the extension's signal to keep using the policy it already has in memory; it is never a
    /// partial policy.
    public func read() -> PolicySnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? Self.decoder.decode(PolicySnapshot.self, from: data),
              snapshot.schemaVersion == PolicySnapshot.currentSchema
        else { return nil }
        return snapshot
    }

    /// Writes the snapshot in a way a reader can never observe half-written.
    public func write(_ snapshot: PolicySnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])

        if fileManager.fileExists(atPath: url.path) {
            try checkReplaceable()
            if let current = read(), snapshot.version < current.version {
                throw StoreError.staleVersion(current: current.version, incoming: snapshot.version)
            }
        }

        let temporary = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        try? fileManager.removeItem(at: temporary)
        try Self.encoder.encode(snapshot).write(to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    /// The file mode and owner, or the error that stops the write. Separated so a test can pin each refusal
    /// without relying on the order the write happens to check them in.
    func checkReplaceable() throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        if mode != 0o600 { throw StoreError.unsafeFileMode(mode ?? 0) }
        if let expectedOwner {
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
            if owner != expectedOwner { throw StoreError.unsafeOwner(owner ?? -1) }
        }
    }
}
