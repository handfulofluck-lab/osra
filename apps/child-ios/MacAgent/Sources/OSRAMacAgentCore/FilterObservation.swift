import Foundation
import OSRAMacAgentFilter
#if canImport(NetworkExtension)
import NetworkExtension
#endif

/// What the system says about the content filter, turned into the one thing the report may say.
///
/// Roadmap 5.9, build step (iii), #988. Codex's requirement: "report web filtering active only after the
/// provider is actually running." This is the only place that asks, and it deliberately keeps the *judgement*
/// separate from the *question*, so the judgement is tested and the question is one call:
///
///  * `assess(observed:policyLoaded:safeSearchRequested:)` is pure and covered by tests;
///  * `current(safeSearchRequested:)` asks NetworkExtension, and is covered by the signed device row instead,
///    because a runner has no filter configuration to read.
public enum FilterObservation {
    /// The mapping from "what the system answered" to the reported state.
    ///
    /// `observed: nil` means the system did not answer. That is reported as `failed` — never as `running`
    /// (an unanswered question about enforcement is not evidence of enforcement) and never as `notInstalled`
    /// (it is not evidence of absence either).
    public static func assess(observed: FilterStatus.Provider?,
                              policyLoaded: Bool,
                              safeSearchRequested: Bool) -> FilterStatus {
        FilterStatus(provider: observed ?? .failed,
                     policyLoaded: policyLoaded,
                     safeSearchRequested: safeSearchRequested)
    }

    #if canImport(NetworkExtension)
    /// Asks the system. `NEFilterManager.status` is the filter configuration's own status: `.invalid` means no
    /// configuration is installed at all, `.connected` means the provider is running, and every other state
    /// means it is installed but not filtering.
    ///
    /// **Unverified on a device:** whether a process that is not the extension — the root daemon, which holds
    /// no NetworkExtension entitlement — may read this. Reading the configuration is separate from changing it
    /// by Apple's own account, but that is my reading rather than a measurement, and it is asked on #988. If the
    /// daemon cannot read it, the same assessment is made extension-side and handed over beside the snapshot;
    /// `assess` does not change.
    public static func current(safeSearchRequested: Bool,
                               store: PolicySnapshotStore = PolicySnapshotStore()) -> FilterStatus {
        let status = NEFilterManager.shared().status
        let observed: FilterStatus.Provider?
        if status == .connected {
            observed = .running
        } else if status == .invalid {
            observed = .notInstalled
        } else {
            observed = .stopped
        }
        return assess(observed: observed,
                      policyLoaded: store.read() != nil,
                      safeSearchRequested: safeSearchRequested)
    }
    #endif
}
