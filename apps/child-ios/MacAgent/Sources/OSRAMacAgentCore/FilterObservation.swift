import Foundation
import OSRAMacAgentFilter

/// What the system says about the content filter, turned into the one thing the report may say.
///
/// Roadmap 5.9, build step (iii), #988. Codex's requirement: "report web filtering active only after the
/// provider is actually running." macOS has no cross-process query for that (`NEFilterManager` exposes the
/// configuration, `isEnabled`, and the `SystemExtensions` API submits extensions rather than reporting them),
/// so the extension writes a liveness file and this decides what it is worth:
///
///  * `provider(liveness:now:maximumAge:)` is pure and covered by tests;
///  * `current(...)` reads two small files, and its truth is the signed device row's.
///
/// Both failure directions matter. An unanswered question is `failed`, never `running`; a stale file — an
/// extension that crashed, was unloaded, or stopped refreshing — is `stopped`, never `running`.
public enum FilterObservation {
    /// How long a liveness file stays believable. The extension refreshes it every minute, so five minutes is
    /// four missed refreshes: long enough not to flap on a busy Mac, short enough that a crash is visible.
    public static let maximumLivenessAge: TimeInterval = 5 * 60

    public static func provider(liveness: FilterLiveness?,
                                now: Date = Date(),
                                maximumAge: TimeInterval = maximumLivenessAge) -> FilterStatus.Provider {
        guard let liveness else { return .failed }
        // A timestamp in the future is a clock that is ahead; the file was written moments ago, so it is fresh.
        // Only an age beyond the window makes it stale.
        guard now.timeIntervalSince(liveness.updatedAt) <= maximumAge else { return .stopped }
        return liveness.running ? .running : .stopped
    }

    public static func assess(liveness: FilterLiveness?,
                              policyLoaded: Bool,
                              safeSearchRequested: Bool,
                              now: Date = Date(),
                              maximumAge: TimeInterval = maximumLivenessAge) -> FilterStatus {
        FilterStatus(provider: provider(liveness: liveness, now: now, maximumAge: maximumAge),
                     policyLoaded: policyLoaded,
                     safeSearchRequested: safeSearchRequested)
    }

    /// Reads both files. The policy answers "was the family asked for SafeSearch", which the Mac cannot
    /// enforce; the liveness file answers "is anything running at all".
    public static func current(safeSearchRequested: Bool,
                               store: PolicySnapshotStore = PolicySnapshotStore(),
                               livenessStore: FilterLivenessStore = FilterLivenessStore(),
                               now: Date = Date()) -> FilterStatus {
        assess(liveness: livenessStore.read(),
               policyLoaded: store.read() != nil,
               safeSearchRequested: safeSearchRequested,
               now: now)
    }
}
