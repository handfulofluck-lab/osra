import Foundation

/// #1090: `ManagedSettingsStore.application.blockedApplications` does not block an app, it *removes* it. iOS takes the
/// icon out of the Home Screen and the App Library, so the app looks like it vanished, and un-hiding it later puts it
/// back in the App Library rather than where it was. A shield (`.shield.applications`) already stops the app and leaves
/// the icon alone, so hiding is the fallback for the one case a shield cannot cover: an app Screen Time gave no token
/// for. Pure, so the tests need no ManagedSettings.
public enum BlockedAppHiding {
    /// The bundle identifiers that must be hidden instead of shielded: those with no Screen Time token, so no shield
    /// can be built for them. Apps that did resolve are left visible — they are shielded, and hiding them is what
    /// moved the child's icon.
    /// [hasToken]: whether Screen Time resolved a token for a bundle identifier; injected so the policy is testable
    /// without FamilyControls.
    public static func hiddenBundleIdentifiers(_ bundleIdentifiers: [String],
                                               hasToken: (String) -> Bool) -> [String] {
        bundleIdentifiers.filter { !hasToken($0) }
    }
}
