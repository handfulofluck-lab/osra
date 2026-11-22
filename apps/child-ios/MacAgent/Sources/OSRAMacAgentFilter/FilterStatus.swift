import Foundation

/// Whether the content filter is actually filtering, which is the only thing that may move `web_filter` out
/// of `unavailable` in the capability report.
///
/// Roadmap 5.9, build step (iii), ADR-0036, ADR-0034. The daemon asks the system whether the extension is
/// running and whether it found a policy; the report says what that answer is, never what the build hopes.
/// The states are the server's own vocabulary (`FEATURE_STATES` in `packages/shared-types`): `ready`,
/// `degraded`, `unavailable`. `not_supported` is the server's word, never the device's.
public struct FilterStatus: Equatable {
    public enum Provider: String, Equatable {
        /// No extension registered with the system yet, or the build has none.
        case notInstalled = "not_installed"
        /// The extension is registered and approved but not running.
        case stopped
        case running
        /// The system refused or stopped it; the reason is in the daemon's log, not in the report.
        case failed
    }

    public var provider: Provider
    /// Whether the running extension found a snapshot it could read. A running filter with no policy allows
    /// everything, so it must not be reported as working.
    public var policyLoaded: Bool

    public init(provider: Provider, policyLoaded: Bool = false) {
        self.provider = provider
        self.policyLoaded = policyLoaded
    }

    /// Not running is not filtering, whatever the policy says.
    public var webFilterState: String {
        guard provider == .running else { return "unavailable" }
        return policyLoaded ? "ready" : "degraded"
    }

    /// Pause-internet takes the default route on the DNS sinkhole; on the Mac it is a separate enforcement
    /// path that this step does not build, so it stays unavailable until that path exists and is proven.
    public var pauseInternetState: String { "unavailable" }
}
