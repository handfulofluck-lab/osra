import Foundation

/// ADR-0034 A6 and ADR-0037 (5.5 PR B2, #372): the iPhone's capability report, sent in the telemetry upload at
/// launch, on an authorization change and on each app open. It says which build this is, what the phone has
/// granted, what it can enforce, and, new here, its app groups as id + label + counts.
///
/// Pure: the inputs are plain values, so the tests build reports without FamilyControls, Core Location or UIKit.
public struct CapabilityReport: Equatable {

    /// iOS's `flavour` (A7): which APNs environment the push token belongs to.
    public enum Flavour: String { case dev, testflight, appstore }

    public struct Client: Equatable {
        public var version: String
        public var build: Int
        public var flavour: Flavour

        public init(version: String, build: Int, flavour: Flavour) {
            self.version = version
            self.build = build
            self.flavour = flavour
        }
    }

    public struct Group: Equatable {
        public var id: String
        public var label: String
        public var counts: AppGroupCounts

        public init(id: String, label: String, counts: AppGroupCounts) {
            self.id = id
            self.label = label
            self.counts = counts
        }
    }

    public var client: Client
    public var screenTime: ScreenTimeStatus
    public var location: LocationGrant
    public var backgroundRefreshOn: Bool
    /// Nil when the groups could not be read: the report then leaves the field out, and the server keeps the last
    /// groups (a report without `groups` never erases them). An empty list says "no groups".
    public var groups: [Group]?

    public init(client: Client, screenTime: ScreenTimeStatus, location: LocationGrant, backgroundRefreshOn: Bool,
                groups: [Group]?) {
        self.client = client
        self.screenTime = screenTime
        self.location = location
        self.backgroundRefreshOn = backgroundRefreshOn
        self.groups = groups
    }

    /// The features no public iOS API offers (ADR-0034 A1); the server recomputes these from its own table anyway.
    static let notSupported = ["lock_screen", "pause_screen", "pause_internet", "uninstall_guard",
                               "notification_scan", "call_sms_log"]

    /// The server's caps (`packages/shared-types`): at most 20 groups.
    static let maxGroups = 20

    /// The JSON object the server's strict `CapabilitiesSchema` accepts.
    public var json: [String: Any] {
        let approved = screenTime == .approved
        let grants: [String: String] = [
            "family_controls": approved ? "granted" : "missing",
            "location": location == .noAccess ? "missing" : "granted",
            "background_refresh": backgroundRefreshOn ? "granted" : "missing",
        ]
        var features: [String: String] = [:]
        for key in Self.notSupported { features[key] = "not_supported" }
        // Picker groups exist since ADR-0037 PR A, so blocking and limits work once Screen Time is allowed.
        features["app_blocking"] = approved ? "ready" : "unavailable"
        features["screen_time"] = approved ? "ready" : "unavailable"
        // Blocked domains apply through WebContentSettings; blocked categories still need picker tokens.
        features["web_filter"] = approved ? "degraded" : "unavailable"
        features["location"] = {
            switch location {
            case .background: return "ready"
            case .whileInUse: return "degraded"
            case .noAccess: return "unavailable"
            }
        }()
        var body: [String: Any] = [
            "client": [
                "app": "child-ios",
                "version": client.version,
                "build": client.build,
                "flavour": client.flavour.rawValue,
            ],
            "grants": grants,
            "features": features,
        ]
        if let groups {
            body["groups"] = Self.wireGroups(groups)
        }
        return body
    }

    /// Groups as the server accepts them: a UUID id, a label cleaned once more (it is child-phone input, and the
    /// server refuses control and direction characters), counts only, at most 20. A group whose label cleans to
    /// nothing, or whose id is not a UUID, is left out rather than costing the whole report.
    static func wireGroups(_ groups: [Group]) -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for group in groups {
            guard out.count < maxGroups,
                  UUID(uuidString: group.id) != nil,
                  seen.insert(group.id.lowercased()).inserted,
                  let label = AppGroupLabel.sanitize(group.label) else { continue }
            out.append([
                "id": group.id,
                "label": label,
                "apps": min(group.counts.apps, 10_000),
                "categories": min(group.counts.categories, 10_000),
                "sites": min(group.counts.sites, 10_000),
            ])
        }
        return out
    }

    /// `X-OSRA-Client` (ADR-0034 A3): `child-ios/<major.minor.patch>+<build> (<flavour>)`, or nil when the version
    /// is not three numbers (the header is a hint; an unparseable one is better left out).
    public var clientHeader: String? {
        let parts = client.version.split(separator: ".")
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isNumber) }),
              client.build >= 0 else { return nil }
        return "child-ios/\(client.version)+\(client.build) (\(client.flavour.rawValue))"
    }
}

extension CapabilityReport.Client {
    /// This build, from the bundle (#693). Debug builds are `dev`. A build that still carries its provisioning
    /// profile (`embedded.mobileprovision`) was signed by a developer, for a device or ad hoc, so it is `dev` too:
    /// App Store and TestFlight signing removes the profile. Only then does the receipt tell TestFlight (sandbox)
    /// from the App Store.
    public static func current(bundle: Bundle = .main) -> CapabilityReport.Client {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let flavour = Self.flavour(isDebug: isDebug,
                                   hasEmbeddedProfile: bundle.path(forResource: "embedded", ofType: "mobileprovision") != nil,
                                   receiptName: bundle.appStoreReceiptURL?.lastPathComponent)
        return CapabilityReport.Client(version: version, build: build, flavour: flavour)
    }

    /// The decision, pure so each kind of build has a row.
    public static func flavour(isDebug: Bool, hasEmbeddedProfile: Bool, receiptName: String?) -> CapabilityReport.Flavour {
        if isDebug || hasEmbeddedProfile { return .dev }
        return receiptName == "sandboxReceipt" ? .testflight : .appstore
    }
}
