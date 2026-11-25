#if DEBUG
import Foundation
import UIKit
import FamilyShieldAgent

/// #739: the launch argument a UI test uses to reach a screen without pairing, under Claude's decision 1 and
/// Ahmed's five conditions.
///
/// **This file exists only in Debug.** The whole body is inside `#if DEBUG`, so a Release build carries neither the
/// argument string nor this type — and `ios-ci.yml` fails the job if either appears in a Release binary rather than
/// trusting that. The identity is a fixed fake that cannot reach a server: it is never a real pairing, it holds no
/// token that works, and it is written only to the simulator's own Keychain and app group.
enum UITestSeed {
    /// `-OSRAUITestSeed <screen>`: the argument a UI test passes to land on a named screen.
    static let argument = "-OSRAUITestSeed"

    /// The screens a test may ask for. Only the parent-PIN setup is reachable this way: every other screen either
    /// needs a real server or must keep asking for the PIN.
    static let pinSetup = "pin-setup"

    /// Writes the fake identity when the argument names a screen it knows, and returns whether it did.
    @discardableResult
    static func apply(arguments: [String] = ProcessInfo.processInfo.arguments,
                      store: (AgentIdentity) -> Bool = AgentIdentityStore.save) -> Bool {
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1),
              arguments[index + 1] == pinSetup else { return false }
        // Ahmed's condition 4: the base URL can never point anywhere real. `127.0.0.1:9` is the discard port on the
        // loopback interface: not this build's server, not staging, not production, and not derived from
        // `OSRA_API_BASE`. Nothing listens there, so every request this identity makes fails closed.
        guard let base = URL(string: "http://127.0.0.1:9") else { return false }
        // Antigravity's B2 (`7043304116`): with every request failing against the discard port, the status screen
        // keeps animating, so XCUITest's "wait for the app to idle" burned its 60-second timeout on every tap — a
        // single wrong-PIN submission cost about six minutes and the UI-test job hit its 30-minute ceiling. Turning
        // animations off is scoped to a **seeded launch only**: nothing here runs in Release (the file is `#if
        // DEBUG`), and nothing runs without the argument, so the agent's behaviour is unchanged everywhere else.
        UIView.setAnimationsEnabled(false)
        let identity = AgentIdentity(apiBaseURL: base,
                                     deviceToken: "uitest-seed-no-token",
                                     deviceId: "uitest-seed-device",
                                     childId: "uitest-seed-child",
                                     familyId: "uitest-seed-family",
                                     hmacSecret: nil,
                                     childName: "UITest Child")
        // Every seeded launch starts clean: the previous row's identity and parent PIN go first, so the rows do not
        // depend on the order the suite runs in. Clearing is not the same as standing in for the PIN — there is no
        // PIN at all afterwards, so every gate still asks for one (Ahmed's condition 5).
        AgentIdentityStore.clear()
        AgentIdentityStore.clearOrphanedSecrets()
        return store(identity)
    }
}
#endif
