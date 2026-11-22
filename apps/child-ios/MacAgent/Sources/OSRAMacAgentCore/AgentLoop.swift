import Foundation
import FamilyShieldAgent

/// The daemon's cycle: prove the secret, drain the command queue, sync the rules, send the heartbeat.
///
/// Cadence, the iPhone agent's contract without a push to wake it:
/// - the **command poll** every 60 s, the server's own interval for a device it cannot wake
///   (`POLL_FAST_SECONDS`, #353). The poll is also what carries a rule change: the server queues
///   `rules_updated`, and the shared `CommandDrainer` answers it with a rule sync, so a change in the parent
///   app reaches this Mac within one poll;
/// - a **rule sync** and a **heartbeat** at start and every 15 minutes whatever the queue says, the telemetry
///   period the server's 20-minute freshness window is built on (ADR-0034 A4).
///
/// The loop decides; everything it touches comes in through `Dependencies`, so the tests run it with no
/// network, keychain or clock.
public final class AgentLoop {
    public enum Cadence {
        public static let poll: TimeInterval = 60
        public static let heartbeat: TimeInterval = 15 * 60
        public static let ruleSync: TimeInterval = 15 * 60
        /// Not paired: look again soon, so a pairing made on the command line is picked up at once.
        public static let unpaired: TimeInterval = 10
        /// The server refused the secret: nothing to do but ask again now and then.
        public static let refused: TimeInterval = 5 * 60
    }

    public enum State: String, Equatable {
        case notPaired = "not_paired"
        /// An identity is stored and the server has not yet confirmed its secret.
        case unverified
        /// The server refused this Mac's secret. Nothing is sent as this device until it pairs again.
        case secretRefused = "secret_refused"
        case paired
    }

    /// One drain of the command queue, reduced to what the loop needs.
    public struct Drain: Equatable {
        public var handled: Int
        public var refused: Int
        public var revoked: Bool

        public init(handled: Int = 0, refused: Int = 0, revoked: Bool = false) {
            self.handled = handled
            self.refused = refused
            self.revoked = revoked
        }
    }

    public enum Sync: Equatable {
        case synced(version: Int)
        case consentWithdrawn
        case notPaired
        case failed
    }

    public struct Dependencies {
        public var loadIdentity: () -> AgentIdentity?
        public var prove: (AgentIdentity) async -> SecretProof.Outcome
        public var drain: () async -> Drain
        public var syncRules: () async -> Sync
        /// Returns the HTTP status, 0 when offline.
        public var heartbeat: (AgentIdentity) async -> Int
        public var childAccount: () -> ChildAccount.Kind?
        public var log: (String) -> Void

        public init(loadIdentity: @escaping () -> AgentIdentity?,
                    prove: @escaping (AgentIdentity) async -> SecretProof.Outcome,
                    drain: @escaping () async -> Drain,
                    syncRules: @escaping () async -> Sync,
                    heartbeat: @escaping (AgentIdentity) async -> Int,
                    childAccount: @escaping () -> ChildAccount.Kind? = { nil },
                    log: @escaping (String) -> Void) {
            self.loadIdentity = loadIdentity
            self.prove = prove
            self.drain = drain
            self.syncRules = syncRules
            self.heartbeat = heartbeat
            self.childAccount = childAccount
            self.log = log
        }
    }

    public private(set) var state: State?
    private let deps: Dependencies
    private var provenDeviceId: String?
    private var lastHeartbeat: Date?
    private var lastRuleSync: Date?

    public init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// One cycle. Returns how long to wait before the next one.
    @discardableResult
    public func tick(now: Date = Date()) async -> TimeInterval {
        guard let identity = deps.loadIdentity() else {
            forgetPairing()
            enter(.notPaired)
            return Cadence.unpaired
        }

        // The secret is proven once per pairing and per launch, before anything is sent as this device.
        if provenDeviceId != identity.deviceId {
            lastHeartbeat = nil
            lastRuleSync = nil
            switch await deps.prove(identity) {
            case .accepted:
                provenDeviceId = identity.deviceId
                enter(.paired)
                if let kind = deps.childAccount() { deps.log("child_account=\(kind.rawValue)") }
            case .refused(let reason):
                enter(.secretRefused, detail: "reason=\(reason)")
                return Cadence.refused
            case .clockSkew:
                enter(.unverified, detail: "reason=clock_skew")
                return Cadence.poll
            case .inconclusive(let status):
                enter(.unverified, detail: "status=\(status)")
                return Cadence.poll
            }
        }

        let drained = await deps.drain()
        if drained.revoked {
            // The parent removed this Mac; the shared code has already cleared the pairing.
            deps.log("event=removed_by_parent")
            forgetPairing()
            enter(.notPaired)
            return Cadence.unpaired
        }
        if drained.handled > 0 || drained.refused > 0 {
            deps.log("event=commands handled=\(drained.handled) refused=\(drained.refused)")
        }

        if isDue(lastRuleSync, every: Cadence.ruleSync, now: now) {
            switch await deps.syncRules() {
            case .synced, .consentWithdrawn:
                lastRuleSync = now
            case .notPaired:
                forgetPairing()
                enter(.notPaired)
                return Cadence.unpaired
            case .failed:
                break // asked again on the next cycle
            }
        }

        if isDue(lastHeartbeat, every: Cadence.heartbeat, now: now) {
            let status = await deps.heartbeat(identity)
            deps.log("event=heartbeat status=\(status)")
            // 202 is stored; 428 is "consent withdrawn", which the server will keep answering until the parent
            // grants it again, so it is not asked every minute. Anything else is sent again on the next cycle.
            if status == 202 || status == 428 { lastHeartbeat = now }
        }
        return Cadence.poll
    }

    private func isDue(_ last: Date?, every interval: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    private func forgetPairing() {
        provenDeviceId = nil
        lastHeartbeat = nil
        lastRuleSync = nil
    }

    /// Logs a state once, when it changes (or its detail does), not on every cycle.
    private var lastStateLine: String?
    private func enter(_ next: State, detail: String? = nil) {
        state = next
        let line = "state=\(next.rawValue)" + (detail.map { " \($0)" } ?? "")
        if line != lastStateLine {
            lastStateLine = line
            deps.log(line)
        }
    }
}

extension AgentLoop.Dependencies {
    /// The real thing: the System keychain, the staging server, the shared sync and command code.
    public static func live(log: @escaping (String) -> Void = AgentLog.write) -> AgentLoop.Dependencies {
        AgentLoop.Dependencies(
            loadIdentity: { AgentRuntime.loadIdentity() },
            prove: { await SecretProof.check($0) },
            drain: {
                let result = await CommandDrainer.drainNow(locator: NoLocation(), sync: { await AgentRuntime.syncRules(log: log).outcome })
                return AgentLoop.Drain(handled: result.handled.count, refused: result.refused.count,
                                       revoked: result.deviceRevoked)
            },
            syncRules: { await AgentRuntime.syncRules(log: log).summary },
            heartbeat: { identity in
                // Step (iii), #988: the report asks the system what the filter is doing, and asks the snapshot
                // whether the family wants SafeSearch — which the Mac cannot enforce, so it degrades the report.
                let snapshot = PolicySnapshotStore().read()
                let status = FilterObservation.current(safeSearchRequested: snapshot?.policy.safeSearchEnforced ?? false)
                return await HeartbeatClient().send(identity, report: MacCapabilityReport(filterStatus: status))
            },
            childAccount: { MacAgentState.childUser().map(ChildAccount.kind(ofUser:)) },
            log: log
        )
    }
}

/// The Mac has no location service in this design: a `locate_now` is answered "failed", out loud, like every
/// other command this agent cannot run.
struct NoLocation: LocateNowHandling {
    func locateNow() async -> LocateAck? { .failed(reason: "not_supported") }
}

/// What the daemon and the command line share: where the identity comes from, and one rule sync.
public enum AgentRuntime {
    /// Call once at start: no keychain prompts, secrets in the System keychain, and a pairing with any server
    /// but this build's is cleared (the iPhone's upgrade rule, #634 G1).
    public static func configure() {
        SystemKeychainSecretStore.forbidPrompts()
        AgentIdentityStore.secrets = SystemKeychainSecretStore()
        AgentIdentityStore.clearIfNotBuiltInServer(MacAgentServer.builtIn)
    }

    /// The stored pairing, only when it is with this build's server.
    public static func loadIdentity() -> AgentIdentity? {
        guard let identity = AgentIdentityStore.load(), MacAgentServer.isBuiltIn(identity.apiBaseURL) else { return nil }
        return identity
    }

    /// One rule sync through the shared `RuleSyncer`. `enforce: false`: the rules are stored for the steps that
    /// will enforce them, and no "applied" version is recorded or reported.
    static func syncRules(log: (String) -> Void) async -> (outcome: RuleSyncer.Outcome, summary: AgentLoop.Sync) {
        let outcome = await RuleSyncer.syncNow(enforce: false)
        switch outcome {
        case .synced(let rules):
            MacAgentState.setRulesVersion(rules.effectiveRulesVersion)
            log("event=rules_synced version=\(rules.effectiveRulesVersion)")
            // Step (iii), #988: the content filter reads this file, not the server. A publish failure is logged
            // and survived — the daemon keeps the rules it has and the extension keeps the policy it read.
            do {
                let published = try MacPolicyPublisher.publish(rules)
                log(published.changed
                    ? "event=policy_published version=\(published.version) rules=\(rules.effectiveRulesVersion)"
                    : "event=policy_unchanged version=\(published.version) rules=\(rules.effectiveRulesVersion)")
            } catch {
                log("event=policy_publish_failed")
            }
            return (outcome, .synced(version: rules.effectiveRulesVersion))
        case .consentWithdrawn:
            MacAgentState.setRulesVersion(nil)
            log("event=rules_cleared reason=consent_withdrawn")
            return (outcome, .consentWithdrawn)
        case .notPaired:
            return (outcome, .notPaired)
        case .failed:
            log("event=rules_sync_failed")
            return (outcome, .failed)
        }
    }
}
