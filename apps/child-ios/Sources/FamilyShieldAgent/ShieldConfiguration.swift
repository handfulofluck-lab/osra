import Foundation

#if canImport(UIKit) && canImport(ManagedSettings) && canImport(ManagedSettingsUI)
import UIKit
import ManagedSettings
import ManagedSettingsUI

/// Shield appearance for FamilyShield block screens (spec §6.3): title, a subtitle
/// describing the rule reason, and the "Ask parent" / "OK" buttons.
///
/// NOTE: this class only takes effect as the NSExtensionPrincipalClass of a Shield
/// Configuration app extension target; the Xcode project wrapping this package
/// supplies that target (SwiftPM alone cannot declare app extensions).
final class FamilyShieldConfigurationDataSource: ShieldConfigurationDataSource {

    /// Shield configuration shown when an application is blocked.
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        Self.makeConfiguration()
    }

    /// Shield configuration shown when a website is blocked.
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        Self.makeConfiguration()
    }

    /// Shared shield layout used for every block reason.
    private static func makeConfiguration() -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: nil,
            backgroundColor: nil,
            icon: nil,
            title: ShieldConfiguration.Label(text: "Blocked by OSRA", color: nil),
            subtitle: ShieldConfiguration.Label(text: Self.subtitle, color: nil),
            primaryButtonLabel: ShieldConfiguration.Label(text: "Ask parent", color: nil),
            primaryButtonBackgroundColor: nil,
            secondaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: nil)
        )
    }

    // NOTE: the exact rule (bedtime, app limit, web filter) is not visible to the
    // shield extension for privacy reasons, so the subtitle describes the reason set.
    private static let subtitle =
        "This app or website is blocked by an OSRA rule (bedtime, app limit, or web filter)."
}

/// Handles taps on FamilyShield shield buttons (spec §6.3): "Ask parent" keeps the
/// shield and notifies the parent; "OK" dismisses the shield and logs a request-access
/// call to the backend.
///
/// NOTE: must be the NSExtensionPrincipalClass of a Shield Action app extension target.
final class FamilyShieldShieldActionDelegate: ShieldActionDelegate {

    private let reporter = AlertReporter(hmacSecret: AlertReporter.pairedHmacSecret())

    /// Handles a shield action raised for a blocked application.
    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(to: action, completionHandler: completionHandler)
    }

    /// Handles a shield action raised for a blocked website.
    override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(to: action, completionHandler: completionHandler)
    }

    /// Routes the tap: the secondary button dismisses the shield, all others keep it up.
    private func respond(to action: ShieldAction, completionHandler: (ShieldActionResponse) -> Void) {
        switch action {
        case .primaryButtonPressed:
            reporter.report(
                category: "app_blocked",
                title: "Child asked for access",
                body: "Child pressed 'Ask parent' on a shield screen.",
                childId: AlertReporter.pairedChildId()
            )
            completionHandler(.none)
        case .secondaryButtonPressed:
            reporter.report(
                category: "app_blocked",
                title: "Shield dismissed by child",
                body: "Child dismissed a shield screen (OK).",
                childId: AlertReporter.pairedChildId()
            )
            // NOTE: .close dismisses the shield and closes the blocked app; a true
            // "allow once" flow would clear the store shield before responding.
            completionHandler(.close)
        default:
            completionHandler(.none)
        }
    }
}
#endif
