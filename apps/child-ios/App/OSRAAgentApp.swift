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
        LocationController.backgroundTask = { name, work in
            let id = UIApplication.shared.beginBackgroundTask(withName: name)
            await work()
            UIApplication.shared.endBackgroundTask(id)
        }
        // Significant-change monitoring relaunches a suspended or terminated app with `.location` (5.5 PR E):
        // the manager is recreated here and monitoring restarts, which delivers the new fix. Every launch
        // also reports the grant, so the server can refuse a locate_now the phone cannot answer.
        LocationController.shared.startIfAllowed()
        Task { await LocationController.shared.reportGrant() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await PushTokenRegistrar.register(tokenHex: PushTokenRegistrar.hex(deviceToken)) }
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            // Under iOS's ~30 s budget for a woken app: past the deadline the drain is cancelled and the wake
            // answers .failed, and the next wake or launch drains again (the queue keeps unacked commands).
            let deadline = CommandDrainer.wakeDeadlineSeconds
            guard let result = await CommandDrainer.drain(within: deadline, {
                let drained = await CommandDrainer.drainNow()
                if drained.consentWithdrawn { await LocationController.shared.stopForConsent() }
                await LocationController.shared.flush()
                return drained
            }) else {
                completionHandler(.failed)
                return
            }
            completionHandler(result.handled.isEmpty && result.refused.isEmpty && !result.consentWithdrawn ? .noData : .newData)
        }
    }
}
