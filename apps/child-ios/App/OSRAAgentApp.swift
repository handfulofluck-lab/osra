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
        // #732: the shield follows the language this app runs in; iOS relaunches the app after a language change.
        SharedLanguage.record()
        // #634 G1: a build locked to its server drops a pairing with any other server (an install over a dev build).
        AgentIdentityStore.clearIfNotBuiltInServer(PairingServerField.builtIn())
        // A reinstall keeps the Keychain but not the app group: drop secrets no identity owns (5.5 PR C). Runs
        // second, so the parent PIN of a pairing cleared above goes too.
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
        NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil,
                                               queue: .main) { _ in SharedLanguage.record() }
        LocationController.backgroundTask = { name, work in
            let id = UIApplication.shared.beginBackgroundTask(withName: name)
            await work()
            UIApplication.shared.endBackgroundTask(id)
        }
        // Significant-change monitoring relaunches a suspended or terminated app with `.location` (5.5 PR E):
        // the manager is recreated here and monitoring restarts, which delivers the new fix. Every launch
        // also reports the grant, so the server can refuse a locate_now the phone cannot answer.
        // ADR-0034 A6 / ADR-0037: every grant upload carries the capability report, app groups included.
        LocationController.capabilityReport = { CapabilityReport.live(location: $0) }
        LocationController.shared.startIfAllowed()
        Task { await LocationController.shared.reportGrant() }
        Task {
            if AgentIdentityStore.load() != nil {
                await RingController.shared.resume()
            } else {
                await RingController.shared.stopForUnpair()
            }
        }
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
