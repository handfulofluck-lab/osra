import Foundation
import OSRAMacAgentFilter

/// The Mac's capability report (ADR-0034), sent with the pairing claim and on every heartbeat.
///
/// At build step (ii) the daemon pairs, syncs and reports, and **enforces nothing**: the content filter is step
/// (iii) and the lock overlay and app blocking are step (iv). So every feature ADR-0036 plans for the Mac is
/// reported `unavailable`, which the parent app shows as not working on this computer. That is the truth today,
/// and the report changes feature by feature as the later steps land. Features with no Mac plan (location, call
/// and SMS log, notification scan, uninstall guard) are left out rather than guessed; `not_supported` is the
/// server's word (A1), never the device's.
///
/// Step (iii), #988: `web_filter` is the first feature to stop being a constant. It says `ready` only when a
/// running provider has a policy it could read, `degraded` when the provider runs without one, and
/// `unavailable` for every other state — see `FilterStatus`. The daemon passes what it observed; nothing here
/// infers that a build that *can* filter is filtering.
public struct MacCapabilityReport: Equatable {
    public static let app = "agent-macos"

    public var version: String
    public var build: Int
    /// `dev` until the notarised installer (step vi) has its own flavour in the server's vocabulary.
    public var flavour: String
    /// What the daemon observed of the content filter. Defaults to "not installed", which is the truth on a
    /// build without step (iii)'s extension.
    public var filterStatus: FilterStatus

    public init(version: String = "0.1.0",
                build: Int = 1,
                flavour: String = "dev",
                filterStatus: FilterStatus = FilterStatus(provider: .notInstalled)) {
        self.version = version
        self.build = build
        self.flavour = flavour
        self.filterStatus = filterStatus
    }

    /// What ADR-0036 plans for the Mac.
    public static let plannedFeatures = ["lock_screen", "pause_screen", "app_blocking", "screen_time", "web_filter",
                                         "pause_internet"]

    /// The JSON object the server's strict `CapabilitiesSchema` accepts. No Mac grant is in the vocabulary yet,
    /// so `grants` is empty.
    public var json: [String: Any] {
        var features: [String: String] = [:]
        for key in Self.plannedFeatures {
            switch key {
            case "web_filter": features[key] = filterStatus.webFilterState
            case "pause_internet": features[key] = filterStatus.pauseInternetState
            default: features[key] = "unavailable"
            }
        }
        return [
            "client": ["app": Self.app, "version": version, "build": build, "flavour": flavour] as [String: Any],
            "grants": [String: String](),
            "features": features,
        ]
    }

    /// `X-OSRA-Client` (ADR-0034 A3): `agent-macos/<major.minor.patch>+<build> (<flavour>)`.
    public var clientHeader: String { "\(Self.app)/\(version)+\(build) (\(flavour))" }
}
