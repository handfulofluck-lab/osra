import Foundation

#if canImport(UIKit) && canImport(ManagedSettings) && canImport(ManagedSettingsUI)
import UIKit
import ManagedSettings
import ManagedSettingsUI

/// Shield appearance for FamilyShield block screens (spec §6.3): the title, the window line (#511) and the
/// "Request access" / "Exit to Home screen" buttons, in English or Arabic.
///
/// NOTE: this class only takes effect as the NSExtensionPrincipalClass of the Shield
/// Configuration extension target (`Extensions/ShieldConfiguration` in `project.yml`;
/// SwiftPM alone cannot declare app extensions). `@objc(...)` gives it that unqualified
/// runtime name, and it is public so the extension can reference it and keep it linked.
@objc(FamilyShieldConfigurationDataSource)
public final class FamilyShieldConfigurationDataSource: ShieldConfigurationDataSource {

    /// Shield configuration shown when an application is blocked.
    public override func configuration(shielding application: Application) -> ShieldConfiguration {
        Self.makeConfiguration(ShieldText.current(bundleIdentifier: application.bundleIdentifier))
    }

    /// Shield configuration shown when a website is blocked. The web filter is not a window, so no line.
    public override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        Self.makeConfiguration(ShieldText.current(bundleIdentifier: nil))
    }

    /// #511: the text comes from `ShieldText`, in the phone's language. Our own rules (bedtime, the routines)
    /// sit in the shared app group, so the extension can name the window holding the app and when it ends; with
    /// no window it shows the title alone.
    private static func makeConfiguration(_ text: ShieldText) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: nil,
            backgroundColor: nil,
            icon: nil,
            title: ShieldConfiguration.Label(text: text.title, color: .label),
            subtitle: text.subtitle.map { ShieldConfiguration.Label(text: $0, color: .secondaryLabel) },
            primaryButtonLabel: ShieldConfiguration.Label(text: text.primaryButton, color: .systemBlue),
            primaryButtonBackgroundColor: nil,
            secondaryButtonLabel: ShieldConfiguration.Label(text: text.secondaryButton, color: .systemGray)
        )
    }
}

/// Handles taps on FamilyShield shield buttons (spec §6.3): "Ask parent" keeps the
/// shield and notifies the parent; "OK" dismisses the shield and logs a request-access
/// call to the backend.
///
/// NOTE: the NSExtensionPrincipalClass of the Shield Action extension target
/// (`Extensions/ShieldAction`); `@objc(...)` and `public` for the same reasons as above.
@objc(FamilyShieldShieldActionDelegate)
public final class FamilyShieldShieldActionDelegate: ShieldActionDelegate {

    private let reporter = AlertReporter(hmacSecret: AlertReporter.pairedHmacSecret())

    /// Handles a shield action raised for a blocked application.
    public override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(to: action, completionHandler: completionHandler)
    }

    /// Handles a shield action raised for a blocked website.
    public override func handle(
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
