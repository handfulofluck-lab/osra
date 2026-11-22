import Foundation
import NetworkExtension
import OSRAMacAgentFilter

/// The content filter's system extension (roadmap 5.9, build step (iii), ADR-0036 decision 3).
///
/// Everything that decides lives in `OSRAMacAgentFilter` and is unit-tested without a signed process; this
/// class only moves bytes: it reads the daemon's snapshot, asks `FilterPolicy` about the flow's URL, and turns
/// the answer into a Network Extension verdict.
///
/// It enforces nothing until three things exist, none of which is in this target: the Developer ID identity,
/// the Network Extension entitlement in a provisioning profile, and the user's approval of the extension.
/// Until then the daemon reports `web_filter` `unavailable`, because it asks the system whether this provider
/// is running rather than assuming.
///
/// The provider is deliberately **fail-open on a missing policy**: a Mac whose daemon has not paired yet, or
/// whose snapshot is unreadable, must not lose its internet. That is safe because the snapshot lives in a
/// root-owned `0600` file, so a Standard user cannot empty it to bypass filtering; the state that matters is
/// reported to the parent as `degraded`, not hidden.
public final class FilterDataProvider: NEFilterDataProvider {
    private let store: PolicySnapshotStore
    private let liveness: FilterLivenessStore
    private var policy: FilterPolicy?
    private var loadedVersion = -1
    private var refreshTimer: Timer?

    public override init() {
        self.store = PolicySnapshotStore()
        self.liveness = FilterLivenessStore()
        super.init()
    }

    /// For a test harness or a future XPC handoff: the same provider over another store.
    init(store: PolicySnapshotStore) {
        self.store = store
        super.init()
    }

    public override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        reload()
        publishLiveness(running: true)
        // The daemon treats a liveness file older than five minutes as a filter that is not running, so this
        // refreshes once a minute. If the extension has no run loop to fire it, the file goes stale and the
        // report under-claims — which is the direction that cannot mislead a parent.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.publishLiveness(running: true)
        }
        completionHandler(nil)
    }

    public override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        publishLiveness(running: false)
        completionHandler()
    }

    private func publishLiveness(running: Bool) {
        try? liveness.write(FilterLiveness(running: running))
    }

    public override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // The daemon writes a new snapshot on every rule sync; re-reading only when its version moves keeps the
        // per-flow cost to one file read, not one per request.
        reloadIfNewer()

        guard let policy, let url = flow.url else { return NEFilterNewFlowVerdict.allow() }
        switch policy.decide(url: url) {
        case .allow:
            return NEFilterNewFlowVerdict.allow()
        case .block:
            return NEFilterNewFlowVerdict.drop()
        case .redirect:
            // There is no redirect verdict on this platform: `NEFilterNewFlowVerdict` has no
            // `redirectRequestURL`, and a content filter cannot rewrite a request. Enforcing SafeSearch on the
            // Mac needs a DNS proxy provider, which rewrites an answer the way the Android sinkhole does — a
            // design change that is Claude's call, asked for on #988. Until then the search is allowed and the
            // intent stays in the decision table, so nobody reads this as a working rewrite.
            return NEFilterNewFlowVerdict.allow()
        }
    }

    private func reload() {
        let snapshot = store.read()
        policy = snapshot?.policy
        loadedVersion = snapshot?.version ?? -1
    }

    private func reloadIfNewer() {
        guard let snapshot = store.read() else { return }
        guard snapshot.version > loadedVersion else { return }
        policy = snapshot.policy
        loadedVersion = snapshot.version
    }
}
