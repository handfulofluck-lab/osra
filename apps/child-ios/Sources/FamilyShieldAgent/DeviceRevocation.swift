import Foundation

/// #690: when the parent removes this phone, every call made with its device token answers
/// `401 {"error":"device_revoked"}` (`services/api/src/middleware/sessionGuard.ts`). The phone then leaves the
/// paired state: the pairing, its rules, the shields they applied, the unsent location and the parent PIN all go,
/// and the app shows the pairing screen. Only that explicit answer counts, so any other 401 (an alert's HMAC, a
/// proxy) never unpairs a phone.
public enum DeviceRevocation {
    /// True only for the server's `device_revoked` answer.
    public static func isRevoked(status: Int, body: Data?) -> Bool {
        guard status == 401, let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object["error"] as? String == "device_revoked"
    }

    /// Lifts the shields the removed family's rules applied. The app's default reaches ManagedSettings; the
    /// package tests replace it.
    public static var clearShields: () -> Void = {
        #if os(iOS)
        ScreenTimeController().clearRules()
        #endif
    }

    public static var stopRing: () -> Void = {
        UserDefaultsRingStore().save(nil)
        Task { await RingController.shared.stopForUnpair() }
    }

    /// Leaves the paired state. The orphan sweep runs after the clear, so the parent PIN goes too and the next
    /// pairing sets a new one.
    public static func unpair() {
        stopRing()
        AgentIdentityStore.clear()
        LocationBuffer.clear()
        AgentIdentityStore.clearOrphanedSecrets()
        clearShields()
    }

    /// Unpairs when the answer is `device_revoked`, and says whether it did.
    @discardableResult
    public static func handle(status: Int, body: Data?) -> Bool {
        guard isRevoked(status: status, body: body) else { return false }
        unpair()
        return true
    }
}
