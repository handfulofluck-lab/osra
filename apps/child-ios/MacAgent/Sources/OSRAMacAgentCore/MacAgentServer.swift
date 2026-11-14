import Foundation
import FamilyShieldAgent

/// The one server this build talks to (#775: "the staging API only, never production"; ADR-0041 D5: pairing
/// has no server field). It is a constant, not a setting: nothing on the Mac, the command line or the launchd
/// job can point the daemon anywhere else. The production address arrives with the notarised installer,
/// build step (vi), as its own reviewed change.
public enum MacAgentServer {
    public static let stagingHost = "api.staging.osratech.com"
    public static let builtIn = URL(string: "https://\(stagingHost)")!

    /// Whether a stored pairing belongs to this build's server (the iPhone's rule, #634 G1).
    public static func isBuiltIn(_ url: URL) -> Bool {
        PairingServerField.sameServer(url.absoluteString, builtIn)
    }
}
