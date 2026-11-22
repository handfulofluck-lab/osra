import Foundation

/// Decides whether the filter extension has to re-read the snapshot, so it does not parse a file on every flow.
///
/// Roadmap 5.9, build step (iii), #988. The first version of `FilterDataProvider` called `store.read()` on every
/// new flow: a JSON decode per connection, thousands of them during an ordinary browsing session, inside the
/// process that sits in the data path. The snapshot changes at most once per rule sync, so the file's
/// modification date is enough to answer "is there anything new", and a `stat` per flow is affordable where a
/// decode is not.
///
/// Two properties, both tested:
///  * **No read when nothing moved.** The same modification date means the policy already in memory is current.
///  * **A read when the file appears, moves, or disappears.** A `nil` date means the file is missing; the first
///    date after that is a change, exactly as a newer date is.
///
/// The bound worth stating: if two writes land within the file system's timestamp granularity, the second is
/// applied on the next change rather than within the same instant. For a child's web filter that is a delay of
/// at most a second on a rule change, and it costs nothing in the direction that matters — the filter never
/// applies a rule it has not read.
public struct SnapshotRefresh: Equatable {
    /// The modification date the cached policy was read at; `nil` means no file was found.
    public private(set) var observedModification: Date?
    /// The version last applied, `-1` before anything has been read.
    public private(set) var appliedVersion: Int

    public init(observedModification: Date? = nil, appliedVersion: Int = -1) {
        self.observedModification = observedModification
        self.appliedVersion = appliedVersion
    }

    /// True when the caller should read the file. Updates the observed date as a side effect, so a caller that
    /// ignores the answer and reads anyway leaves the cache correct.
    public mutating func shouldReload(fileModification: Date?) -> Bool {
        guard fileModification != observedModification else { return false }
        observedModification = fileModification
        return true
    }

    /// Records what was actually applied, so a read that returns nothing (a corrupt file) does not leave the
    /// cache claiming a version it never loaded.
    public mutating func applied(_ snapshot: PolicySnapshot?) {
        appliedVersion = snapshot?.version ?? -1
    }
}
