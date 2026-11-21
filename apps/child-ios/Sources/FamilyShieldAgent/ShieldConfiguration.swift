import Foundation

#if os(iOS)
import UIKit
import ManagedSettings
import ManagedSettingsUI
import os

/// Shield appearance for FamilyShield block screens (spec §6.3): the title, the window line (#511) and the
/// "Request access" / "Exit to Home screen" buttons, in English or Arabic.
///
/// #561: the extension's principal class is `ShieldConfigurationExtension`, declared in
/// `Extensions/ShieldConfiguration` as a subclass of this one (iOS could not load an `@objc`-renamed class from the
/// package on the device: `ExtensionError Code=0`). This class is `open` so that subclass can exist; the behaviour stays here, under test.
open class FamilyShieldConfigurationDataSource: ShieldConfigurationDataSource {

    private static let logger = Logger(subsystem: "com.osratech.child", category: "Shield")

    /// Shield configuration shown when an application is blocked.
    public override func configuration(shielding application: Application) -> ShieldConfiguration {
        Self.makeConfiguration(ShieldText.current(bundleIdentifier: application.bundleIdentifier))
    }

    /// Shield configuration shown when a website is blocked. The web filter is not a window, so no line.
    public override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        Self.makeConfiguration(ShieldText.current(bundleIdentifier: nil))
    }

    /// ADR-0037: an app shielded through a blocked group's category gets the same OSRA shield.
    public override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        Self.makeConfiguration(ShieldText.current(bundleIdentifier: application.bundleIdentifier))
    }

    /// ADR-0037: a website shielded through a blocked group's category.
    public override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        Self.makeConfiguration(ShieldText.current(bundleIdentifier: nil))
    }

    /// #511: the text comes from `ShieldText`, in the phone's language. Our own rules (bedtime, the routines)
    /// sit in the shared app group, so the extension can name the window holding the app and when it ends; with
    /// no window it shows the title alone.
    private static func makeConfiguration(_ text: ShieldText) -> ShieldConfiguration {
        #if DEBUG
        // #654 device row: what the extension process is told about languages, to confirm the cause.
        let preferred = ShieldText.freshPreferredLanguages().joined(separator: ",")
        let standard = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String] ?? []).joined(separator: ",")
        let bundle = Bundle.main.preferredLocalizations.joined(separator: ",")
        let stored = SharedLanguage.stored() ?? "none"
        let chosen = ShieldText.resolvedLanguage()
        logger.debug("shield_language preferred=\(preferred, privacy: .public) standard=\(standard, privacy: .public) locale=\(Locale.current.identifier, privacy: .public) bundle=\(bundle, privacy: .public) stored=\(stored, privacy: .public) chosen=\(chosen, privacy: .public)")
        #endif
        return ShieldConfiguration(
            backgroundBlurStyle: nil,
            backgroundColor: nil,
            icon: nil,
            title: ShieldConfiguration.Label(text: text.title, color: .label),
            subtitle: text.subtitle.map { ShieldConfiguration.Label(text: $0, color: .secondaryLabel) },
            // U14: one fixed pair in both modes; the shield ignores a dynamic label colour on a device (ShieldPalette).
            primaryButtonLabel: ShieldConfiguration.Label(text: text.primaryButton, color: Self.color(ShieldPalette.buttonLabel)),
            primaryButtonBackgroundColor: Self.color(ShieldPalette.buttonBackground),
            secondaryButtonLabel: ShieldConfiguration.Label(text: text.secondaryButton, color: .label)
        )
    }

    /// A fixed colour, the same in light and dark.
    private static func color(_ c: ShieldPalette.RGB) -> UIColor {
        UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}

/// Handles taps on FamilyShield shield buttons (spec §6.3): "Request access" keeps the shield and notifies the
/// parent; "Exit to Home screen" closes the blocked app and is only counted (#602, `ShieldTapPolicy`).
///
/// #561: subclassed by `ShieldActionExtension` in `Extensions/ShieldAction`, the extension's principal class.
open class FamilyShieldShieldActionDelegate: ShieldActionDelegate {

    private let reporter = AlertReporter(hmacSecret: AlertReporter.pairedHmacSecret())

    /// Handles a shield action raised for a blocked application.
    public override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(to: action, target: Self.target("app", application), completionHandler: completionHandler)
    }

    /// Handles a shield action raised for a blocked website.
    public override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(to: action, target: Self.target("web", webDomain), completionHandler: completionHandler)
    }

    /// ADR-0037: a tap on the shield of an app blocked through a group's category; Ask parent works the same.
    public override func handle(
        action: ShieldAction,
        for category: ActivityCategoryToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(to: action, target: Self.target("category", category), completionHandler: completionHandler)
    }

    /// An opaque local key for the shielded app, website or category (#744). Tokens are Codable; the key never
    /// leaves the app group.
    private static func target<T: Encodable>(_ kind: String, _ token: T) -> String {
        let encoded = (try? JSONEncoder().encode(token))?.base64EncodedString() ?? "unknown"
        return "\(kind):\(encoded)"
    }

    /// Routes the tap through `ShieldTapPolicy` (#602): Request access alerts the parent and keeps the shield;
    /// Exit to Home closes the app, is counted, and sends nothing.
    private func respond(to action: ShieldAction, target: String, completionHandler: (ShieldActionResponse) -> Void) {
        let tap: ShieldTapPolicy.Tap
        switch action {
        case .primaryButtonPressed: tap = .requestAccess
        case .secondaryButtonPressed: tap = .exitHome
        default: tap = .other
        }
        let outcome = ShieldTapPolicy.outcome(tap)
        // #744: one request per target every few minutes; further taps keep the shield and send nothing.
        if outcome.alertsParent,
           ShieldTapPolicy.shouldSendRequest(target: target, defaults: UserDefaults(suiteName: AgentIdentityStore.suiteName)) {
            reporter.report(
                category: "app_blocked",
                title: "Child asked for access",
                body: "Child pressed 'Ask parent' on a shield screen.",
                childId: AlertReporter.pairedChildId()
            )
        }
        if outcome.countsDismissal {
            ShieldTapPolicy.countDismissal(in: UserDefaults(suiteName: AgentIdentityStore.suiteName))
        }
        // NOTE: .close dismisses the shield and closes the blocked app; a true
        // "allow once" flow would clear the store shield before responding.
        completionHandler(outcome.closesApp ? .close : .none)
    }
}
#endif
