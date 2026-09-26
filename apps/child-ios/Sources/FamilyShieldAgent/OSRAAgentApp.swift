#if canImport(SwiftUI)
import SwiftUI

/// Host-app entry point for the iOS child agent.
///
/// NOTE (build plumbing): SwiftPM builds this package as a library, so this
/// `@main` only *runs* when the Xcode wrapper project (still to be committed —
/// see QA-IOS.md) links this target into the host app executable. The wrapper
/// must also add the `com.apple.developer.family-controls` entitlement, the
/// `group.dev.familyshield.agent` app-group entitlement (replace the
/// placeholder in `AgentIdentityStore.suiteName` / `AlertReporter` when the
/// real id is chosen), and the Shield / Shield Action / Device Activity
/// extension targets whose NSExtensionPrincipalClass values point at
/// `FamilyShieldConfigurationDataSource`, `FamilyShieldShieldActionDelegate`
/// and `FamilyShieldDeviceActivityMonitor`.
@main
public struct OSRAAgentApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            AgentRootView()
        }
    }
}
#endif
