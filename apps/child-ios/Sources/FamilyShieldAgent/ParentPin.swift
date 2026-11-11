import CommonCrypto
import Foundation
import Security

/// The parent PIN on the iPhone (ADR-0037, following ADR-0010 to the letter so both platforms behave the same).
/// It gates the "App groups" screen and re-pairing. It is set on the phone at pairing and never leaves it: no PIN
/// or hash exists on the server.
///
/// Same rules and storage format as Android's `ParentPin.kt`: 4-8 digits, not all one digit, not on the weak list;
/// PBKDF2-HMAC-SHA256 at 120,000 iterations with a 16-byte random salt, stored as
/// `pbkdf2$<iterations>$<saltB64>$<hashB64>`; a constant-time compare. Both suites read the same cases from
/// `docs/test-vectors/parent-pin.tsv`.
public enum ParentPin {
    public static let iterations: UInt32 = 120_000
    public static let minLength = 4
    public static let maxLength = 8
    static let keyBytes = 32
    static let saltBytes = 16

    static let weakPins: Set<String> = ["1234", "0000", "1111", "1212", "12345", "123456", "111111", "654321"]

    /// Nil when acceptable, else the refusal Android shows, word for word.
    public static func validationError(_ pin: String) -> String? {
        if pin.count < minLength { return "PIN must be at least \(minLength) digits." }
        if pin.count > maxLength { return "PIN must be at most \(maxLength) digits." }
        if !pin.allSatisfy({ ("0"..."9").contains($0) }) { return "PIN must be digits only." }
        if Set(pin).count == 1 { return "Choose a PIN that is not all the same digit." }
        if weakPins.contains(pin) { return "Choose a less predictable PIN." }
        return nil
    }

    /// Hashes `pin` with a fresh random salt into the storable string.
    public static func hash(_ pin: String) -> String? {
        var salt = [UInt8](repeating: 0, count: saltBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes, &salt) == errSecSuccess,
              let derived = pbkdf2(pin, salt: salt, iterations: iterations) else { return nil }
        return "pbkdf2$\(iterations)$\(Data(salt).base64EncodedString())$\(Data(derived).base64EncodedString())"
    }

    /// Constant-time check of `pin` against `stored`; false on any malformed or missing value.
    public static func verify(_ pin: String, stored: String?) -> Bool {
        guard let stored, !stored.isEmpty else { return false }
        let parts = stored.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "pbkdf2", let rounds = UInt32(parts[1]), rounds > 0,
              let salt = Data(base64Encoded: parts[2]), let expected = Data(base64Encoded: parts[3]),
              let actual = pbkdf2(pin, salt: [UInt8](salt), iterations: rounds) else { return false }
        return constantTimeEquals([UInt8](expected), actual)
    }

    static func pbkdf2(_ pin: String, salt: [UInt8], iterations: UInt32) -> [UInt8]? {
        var derived = [UInt8](repeating: 0, count: keyBytes)
        // The String bridges to a C string; its UTF-8 length is the password length (digits only, so 1 byte each).
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pin, pin.utf8.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                          &derived, keyBytes)
        return status == Int32(kCCSuccess) ? derived : nil
    }

    /// Compares every byte whatever the first difference, so the time taken says nothing about the PIN.
    static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

/// After five wrong PINs in a row the gate locks, for 30 s at first and twice as long for each further wrong PIN,
/// up to an hour. Nothing is ever wiped. A correct PIN resets it. Pure, so the tests drive the clock.
public struct PinLockout: Codable, Equatable {
    public static let freeAttempts = 5
    public static let firstDelay: TimeInterval = 30
    public static let maxDelay: TimeInterval = 60 * 60

    public private(set) var failures: Int = 0
    public private(set) var lockedUntil: Date?

    public init() {}

    public func isLocked(now: Date) -> Bool { remaining(now: now) > 0 }

    public func remaining(now: Date) -> TimeInterval {
        guard let lockedUntil else { return 0 }
        return max(0, lockedUntil.timeIntervalSince(now))
    }

    public mutating func recordFailure(now: Date) {
        failures += 1
        guard failures >= Self.freeAttempts else { return }
        let doublings = Double(failures - Self.freeAttempts)
        let delay = min(Self.maxDelay, Self.firstDelay * pow(2, doublings))
        lockedUntil = now.addingTimeInterval(delay)
    }

    public mutating func recordSuccess() {
        failures = 0
        lockedUntil = nil
    }
}

/// The stored PIN hash (Keychain, through [SecretStore], the same store as the device secrets) and the lockout
/// (app-group defaults). A reinstall clears both: the lockout lives in the container, and the hash is removed as an
/// orphan by `AgentIdentityStore.clearOrphanedSecrets()`.
public enum ParentPinStore {
    static let account = "parentPin"
    static let lockoutKey = "pin.lockout"

    public enum Check: Equatable {
        case ok
        case wrong(attemptsLeft: Int)
        case locked(seconds: Int)
    }

    public static var isConfigured: Bool { !(AgentIdentityStore.secrets.read(account) ?? "").isEmpty }

    /// Stores a validated PIN; false when it is refused or the Keychain refused the write.
    @discardableResult
    public static func set(_ pin: String) -> Bool {
        guard ParentPin.validationError(pin) == nil, let hashed = ParentPin.hash(pin) else { return false }
        guard AgentIdentityStore.secrets.write(hashed, for: account) else { return false }
        saveLockout(PinLockout())
        return true
    }

    /// Checks `pin`, counting failures; while locked, the PIN is not even compared.
    public static func check(_ pin: String, now: Date = Date()) -> Check {
        var lockout = loadLockout()
        if lockout.isLocked(now: now) { return .locked(seconds: Int(lockout.remaining(now: now).rounded(.up))) }
        if ParentPin.verify(pin, stored: AgentIdentityStore.secrets.read(account)) {
            lockout.recordSuccess()
            saveLockout(lockout)
            return .ok
        }
        lockout.recordFailure(now: now)
        saveLockout(lockout)
        if lockout.isLocked(now: now) { return .locked(seconds: Int(lockout.remaining(now: now).rounded(.up))) }
        return .wrong(attemptsLeft: PinLockout.freeAttempts - lockout.failures)
    }

    static func clear() {
        AgentIdentityStore.secrets.delete(account)
        defaults?.removeObject(forKey: lockoutKey)
    }

    static func loadLockout() -> PinLockout {
        guard let data = defaults?.data(forKey: lockoutKey),
              let lockout = try? JSONDecoder().decode(PinLockout.self, from: data) else { return PinLockout() }
        return lockout
    }

    static func saveLockout(_ lockout: PinLockout) {
        defaults?.set(try? JSONEncoder().encode(lockout), forKey: lockoutKey)
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AgentIdentityStore.suiteName) }
}

/// The line under the PIN field, for each answer.
public enum PinGateMessage {
    public static func text(for result: ParentPinStore.Check) -> String? {
        switch result {
        case .ok: return nil
        case .wrong(let left): return "Wrong PIN. \(left) \(left == 1 ? "try" : "tries") left before a pause."
        case .locked(let seconds): return "Too many wrong PINs. Try again in \(seconds) s."
        }
    }
}
