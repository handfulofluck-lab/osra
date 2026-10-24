import SwiftUI
import FamilyShieldAgent

/// Host-app entry point for the iOS child agent (target `OSRAAgent` in `project.yml`).
///
/// The app is a thin shell: the pairing UI, the Screen Time logic and the extension
/// principal classes all live in the `FamilyShieldAgent` package, which every target links.
/// `@main` lives here rather than in the package, because a library cannot have an entry point.
@main
struct OSRAAgentApp: App {
    init() {
        // A reinstall keeps the Keychain but not the app group: drop secrets no identity owns (5.5 PR C).
        AgentIdentityStore.clearOrphanedSecrets()
    }

    var body: some Scene {
        WindowGroup {
            AgentRootView()
        }
    }
}
