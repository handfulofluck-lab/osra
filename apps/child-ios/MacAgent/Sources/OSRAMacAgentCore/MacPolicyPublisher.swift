import Foundation
import FamilyShieldAgent
import OSRAMacAgentFilter

/// Turns a rule sync into the file the content filter reads.
///
/// Roadmap 5.9, build step (iii), #988. The daemon already syncs rules on start, every 15 minutes and whenever
/// the server queues `rules_updated`; this is the one place that copies the family's *web* rules out of that
/// sync and into the snapshot, so the extension never talks to the server and never sees a token.
///
/// Three rules, each with a test:
///  * **Version rises, and only for a real change.** A sync that carries the same rules writes nothing, so a
///    fifteen-minute heartbeat does not churn the file the extension is reading. A real change writes
///    `previous + 1`, read back from the file, so the counter survives a daemon restart.
///  * **Pause is not published from rules.** `pause_internet` is a command with its own lifetime, and this
///    step does not build its enforcement; publishing `pausedInternet: true` from a stale rule sync would
///    leave the Mac's internet off after the parent resumed. It stays `false` until the pause path exists.
///  * **A failed write is the caller's to log, not a crash.** The daemon keeps running with the last policy it
///    published; the extension keeps the last one it read.
public enum MacPolicyPublisher {
    public struct Published: Equatable {
        public var version: Int
        /// False when the rules were unchanged and nothing was written.
        public var changed: Bool

        public init(version: Int, changed: Bool) {
            self.version = version
            self.changed = changed
        }
    }

    /// The policy a rule set describes. Categories are deliberately empty: the blocklist pack that maps a
    /// domain to a category exists only on Android today, and inventing one here would be a different step.
    public static func policy(for rules: RuleSet) -> FilterPolicy {
        FilterPolicy(pausedInternet: false,
                     safeSearchEnforced: rules.webFilter.safeSearchEnforced,
                     allowedDomains: rules.webFilter.allowedDomains,
                     blockedDomains: rules.webFilter.blockedDomains,
                     categoryDomains: [:])
    }

    /// Consent withdrawn: stop enforcing. The shared syncer clears the stored rules on that outcome, and the
    /// filter must stop blocking too — a Mac that keeps sinking domains after a family revoked consent is
    /// enforcing a policy nobody holds any more. An empty policy is published rather than the file deleted, so
    /// the version keeps rising and the extension applies the change on its next look.
    @discardableResult
    public static func clear(store: PolicySnapshotStore = PolicySnapshotStore(),
                             now: Date = Date()) throws -> Published {
        let current = store.read()
        if let current, current.policy == FilterPolicy() { return Published(version: current.version, changed: false) }
        let version = (current?.version ?? 0) + 1
        try store.write(PolicySnapshot(version: version, rulesVersion: 0, policy: FilterPolicy(), writtenAt: now))
        return Published(version: version, changed: true)
    }

    /// Writes the snapshot when the rules say something new. Returns the version now on disk.
    @discardableResult
    public static func publish(_ rules: RuleSet,
                               store: PolicySnapshotStore = PolicySnapshotStore(),
                               now: Date = Date()) throws -> Published {
        let next = policy(for: rules)
        let current = store.read()
        if let current, current.policy == next, current.rulesVersion == rules.effectiveRulesVersion {
            return Published(version: current.version, changed: false)
        }
        // Read from the file rather than from `MacAgentState`, so the counter cannot go backwards after a
        // restart, a reinstall that kept the file, or a daemon that died mid-cycle.
        let version = (current?.version ?? 0) + 1
        try store.write(PolicySnapshot(version: version,
                                       rulesVersion: rules.effectiveRulesVersion,
                                       policy: next,
                                       writtenAt: now))
        return Published(version: version, changed: true)
    }
}
