import SwiftUI
import UIKit
import FamilyShieldAgent

/// Host-app entry point for the iOS child agent (target `OSRAAgent` in `project.yml`).
///
/// The app is a thin shell: the pairing UI, the Screen Time logic and the extension
/// principal classes all live in the `FamilyShieldAgent` package, which every target links.
/// `@main` lives here rather than in the package, because a library cannot have an entry point.
@main
struct OSRAAgentApp: App {
    @UIApplicationDelegateAdaptor(OSRAAgentAppDelegate.self) private var appDelegate

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

/// APNs (5.5 PR D): registers for remote notifications, uploads the token, and drains the command queue
/// when a wake push arrives. The wake carries no command (`{"w":"1"}`, #319); the queue is read over the
/// authenticated channel. A real token needs a signed build with the push entitlement (5.1).
final class OSRAAgentAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await PushTokenRegistrar.register(tokenHex: PushTokenRegistrar.hex(deviceToken)) }
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            let result = await CommandDrainer.drainNow()
            completionHandler(result.handled.isEmpty && result.refused.isEmpty && !result.consentWithdrawn ? .noData : .newData)
        }
    }
}
