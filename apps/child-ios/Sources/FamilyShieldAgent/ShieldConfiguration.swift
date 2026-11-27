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
        Self.makeConfiguration(Self.textAndRecord(bundleIdentifier: application.bundleIdentifier))
    }

    /// Shield configuration shown when a website is blocked. The web filter is not a window, so no line.
    public override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        Self.makeConfiguration(Self.textAndRecord(bundleIdentifier: nil))
    }

    /// ADR-0037: an app shielded through a blocked group's category gets the same OSRA shield.
    public override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        Self.makeConfiguration(Self.textAndRecord(bundleIdentifier: application.bundleIdentifier))
    }

    /// ADR-0037: a website shielded through a blocked group's category.
    public override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        Self.makeConfiguration(Self.textAndRecord(bundleIdentifier: nil))
    }

    /// U105, Codex's first finding: resolve the cause **once**, record it for the tap, and render the text from the
    /// same answer — so a shield reading "Blocked by Bedtime" can never send a time request.
    private static func textAndRecord(bundleIdentifier: String?) -> ShieldText {
        DailyLimitRequestStore.clearIfStale()
        let resetsAt = dailyLimitResetsAt()
        let sent = resetsAt.flatMap { DailyLimitRequestStore.recordedResetsAt(matching: $0) }
        let situation = ShieldText.resolve(bundleIdentifier: bundleIdentifier,
                                           dailyLimitResetsAt: resetsAt,
                                           requestSentResetsAt: sent)
        ShieldCauseStore.record(situation)
        return ShieldText.make(situation: situation, language: ShieldText.resolvedLanguage())
    }

    /// U105: how many minutes the shield asks for. The iOS shield has one button and no picker, so this is a fixed
    /// ask; 15 matches the shortest Android option (`+15 min`).
    static let dailyLimitRequestMinutes = 15

    /// U105: the daily limit's reset time when the limit is what holds the shield, nil when it is not. The limit is
    /// not a window, so it is only offered to `ShieldText` when nothing else explains the shield.
    static func dailyLimitResetsAt(now: Date = Date()) -> Date? {
        // The daily limit is iOS 17.4+ (`DailyScreenTimeMonitor`), so an older phone simply has no limit to name.
        guard #available(iOS 17.4, *) else { return nil }
        let status = DailyScreenTimeMonitor.dailyLimitStatus(now: now)
        return status.exhausted ? status.resetsAt : nil
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
            primaryButtonLabel: ShieldConfiguration.Label(text: text.primaryButton, color: .systemBlue),
            primaryButtonBackgroundColor: nil,
            secondaryButtonLabel: ShieldConfiguration.Label(text: text.secondaryButton, color: .systemGray)
        )
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

    /// ADR-0037: a tap on the shield of an app blocked through a group's category; Request access works the same.
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
            // U105: when the daily limit is what holds the shield, the tap asks for time the way Android does, so
            // the parent's time-request card renders it rather than a generic access alert.
            // U105, Codex's findings: the tap follows the cause the shield was **drawn** with, not a fresh guess,
            // and a sent request is recorded against its reset so the next configuration shows the confirmation.
            if ShieldCauseStore.lastDrawnWasDailyLimit, let resetsAt = ShieldCauseStore.lastDrawnResetsAt {
                reporter.reportTimeRequest(minutes: Self.dailyLimitRequestMinutes,
                                           childId: AlertReporter.pairedChildId())
                DailyLimitRequestStore.record(resetsAt: resetsAt)
            } else {
                reporter.report(
                    category: "app_blocked",
                    title: "Child asked for access",
                    body: ShieldTapPolicy.requestAccessAlertBody,
                    childId: AlertReporter.pairedChildId()
                )
            }
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
