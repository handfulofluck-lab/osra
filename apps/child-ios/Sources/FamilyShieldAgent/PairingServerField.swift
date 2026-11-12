import Foundation

/// #634 gate item G1, the rule Android has since #553 and the parent app since #579: a store build carries its
/// server (`OSRA_API_BASE`, a build setting written into Info.plist as `OSRAAPIBase`). When it does, the pairing
/// screen shows that server, locked, and pairs with nothing else; only an `https://` value counts. A build without
/// it (simulator, local testing) keeps the editable field exactly as before.
public enum PairingServerField {
    public static let infoKey = "OSRAAPIBase"

    public struct Field: Equatable {
        public let value: String
        public let locked: Bool
    }

    /// The built-in server, or nil when the build has none: unset, an unexpanded `$(…)`, or not an https URL.
    public static func builtIn(_ raw: String?) -> URL? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !s.hasPrefix("$(") else {
            return nil
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// The built-in server of this app (Info.plist).
    public static func builtIn(bundle: Bundle = .main) -> URL? {
        builtIn(bundle.object(forInfoDictionaryKey: infoKey) as? String)
    }

    /// What the field shows: the built-in server, locked, whenever there is one; else what was used before.
    public static func field(builtIn: URL?, previous: String) -> Field {
        if let builtIn { return Field(value: builtIn.absoluteString, locked: true) }
        return Field(value: previous, locked: false)
    }

    /// The server to pair with: always the built-in one when there is one, whatever the field holds.
    public static func serverToPair(builtIn: URL?, typed: String) -> URL? {
        builtIn ?? PairingClient.normalizeServerURL(typed)
    }
}
