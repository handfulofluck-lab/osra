import Darwin
import Foundation
import FamilyShieldAgent

/// The `osra-agent` commands. `run` is the launch daemon; the rest are the root-only hooks the test bed and,
/// later, the installer use. This step has no screen: the pairing window, the parent PIN and every sentence a
/// family reads belong to the menu-bar app (ADR-0036 step iv) and go through the Bureaus there. What these
/// commands print is fixed machine words (`paired`, `error: code_expired`), not copy.
///
///     osra-agent run
///     osra-agent pair [<6-digit code>] [--child-user <account>] [--device-name <name>]
///     osra-agent status
///     osra-agent unpair
///     osra-agent version
///
/// `pair` takes the pairing code and nothing else about the server (ADR-0041 D5): there is no server option.
public enum AgentCLI {
    public enum Exit {
        public static let ok: Int32 = 0
        public static let failed: Int32 = 1
        public static let usage: Int32 = 64
        public static let needsRoot: Int32 = 77
    }

    public enum Command: Equatable {
        case run
        case pair(code: String?, childUser: String?, deviceName: String?)
        case status
        case unpair
        case version
    }

    /// Parses the arguments; nil is a usage error. Pure.
    public static func parse(_ arguments: [String]) -> Command? {
        guard let name = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "run": return rest.isEmpty ? .run : nil
        case "status": return rest.isEmpty ? .status : nil
        case "unpair": return rest.isEmpty ? .unpair : nil
        case "version": return rest.isEmpty ? .version : nil
        case "pair":
            var code: String?
            var childUser: String?
            var deviceName: String?
            var index = 0
            while index < rest.count {
                let argument = rest[index]
                switch argument {
                case "--child-user", "--device-name":
                    guard index + 1 < rest.count else { return nil }
                    if argument == "--child-user" { childUser = rest[index + 1] } else { deviceName = rest[index + 1] }
                    index += 2
                default:
                    // Anything else that looks like an option is refused: there is no server option to find.
                    guard !argument.hasPrefix("-"), code == nil else { return nil }
                    code = argument
                    index += 1
                }
            }
            return .pair(code: code, childUser: childUser, deviceName: deviceName)
        default:
            return nil
        }
    }

    /// Exactly six digits, as the server requires.
    public static func isPairingCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The fixed word for each way pairing can end; never the server's own text.
    public static func word(for error: Error) -> String {
        switch error {
        case PairingError.invalidCode: return "invalid_code"
        case PairingError.httpError(let status) where status == 404: return "code_unknown_or_expired"
        case PairingError.httpError(let status): return "server_answered_\(status)"
        case PairingError.alreadyClaimed: return "code_in_use"
        case PairingError.denied: return "denied_by_parent"
        case PairingError.expired: return "code_expired"
        case PairingError.consentRequired: return "consent_required"
        case PairingError.unusableResponse, PairingError.invalidServerURL: return "unusable_answer"
        default: return "network"
        }
    }

    public static func main(_ arguments: [String]) async -> Int32 {
        guard let command = parse(arguments) else {
            say("usage: osra-agent run | pair [<code>] [--child-user <account>] [--device-name <name>] | status | unpair | version")
            return Exit.usage
        }
        if command == .version {
            say(MacCapabilityReport().clientHeader)
            return Exit.ok
        }
        // The System keychain and root's preferences are root's: every other command needs root.
        guard geteuid() == 0 else {
            say("error: needs_root")
            return Exit.needsRoot
        }
        AgentRuntime.configure()
        switch command {
        case .run: return await run()
        case .pair(let code, let childUser, let deviceName):
            return await pair(code: code, childUser: childUser, deviceName: deviceName)
        case .status: return await status()
        case .unpair: return unpair()
        case .version: return Exit.ok
        }
    }

    // MARK: - run

    private static func run() async -> Int32 {
        AgentLog.write("event=start client=\(MacCapabilityReport().clientHeader)")
        let loop = AgentLoop(.live())
        while true {
            let wait = await loop.tick()
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    // MARK: - pair

    private static func pair(code given: String?, childUser: String?, deviceName: String?) async -> Int32 {
        // With no code on the command line it is read from standard input, so it need not sit in shell history.
        let code = (given ?? readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPairingCode(code) else {
            say("error: invalid_code")
            return Exit.usage
        }
        var childKind: ChildAccount.Kind?
        if let childUser {
            let kind = ChildAccount.kind(ofUser: childUser)
            guard kind != .unknown else {
                say("error: unknown_child_user")
                return Exit.usage
            }
            childKind = kind
        }
        // Before the code is spent: a keychain that refuses the daemon would leave the server with a device
        // this Mac cannot be.
        guard SystemKeychainSecretStore().selfTest() else {
            say("error: keychain_unavailable")
            return Exit.failed
        }

        say("waiting_for_parent")
        let identity: AgentIdentity
        do {
            identity = try await PairingClient().claim(baseURL: MacAgentServer.builtIn, code: code,
                                                       deviceName: deviceName ?? MacDevice.computerName(),
                                                       device: MacDevice.claimDevice())
        } catch {
            say("error: \(word(for: error))")
            return Exit.failed
        }

        // Nothing is stored, and nothing says "paired", until the server has accepted this Mac's signature.
        switch await proveWithRetries(identity) {
        case .accepted:
            break
        case .refused(let reason):
            say("error: secret_refused \(reason)")
            return Exit.failed
        case .clockSkew:
            say("error: secret_unverified clock_skew")
            return Exit.failed
        case .inconclusive(let status):
            say("error: secret_unverified status_\(status)")
            return Exit.failed
        }
        guard AgentIdentityStore.saveNewPairing(identity) else {
            say("error: store_failed")
            return Exit.failed
        }
        MacAgentState.setRulesVersion(nil)
        MacAgentState.setChildUser(childUser)
        AgentLog.write("event=paired_on_command_line")
        say("paired")
        switch childKind {
        case .administrator?: say("warning: child_account_admin")
        case .standard?: say("child_account: standard")
        default: say("note: child_account_unchecked")
        }
        return Exit.ok
    }

    /// An offline moment or a slow clock answer is asked again; a refusal is final at once.
    static func proveWithRetries(_ identity: AgentIdentity, attempts: Int = 3,
                                 prove: (AgentIdentity) async -> SecretProof.Outcome = { await SecretProof.check($0) },
                                 sleep: (UInt64) async -> Void = { _ = try? await Task.sleep(nanoseconds: $0) }) async -> SecretProof.Outcome {
        var last = SecretProof.Outcome.inconclusive(0)
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { await sleep(2_000_000_000) }
            last = await prove(identity)
            switch last {
            case .accepted, .refused: return last
            case .clockSkew, .inconclusive: continue
            }
        }
        return last
    }

    // MARK: - status

    private static func status() async -> Int32 {
        guard let identity = AgentRuntime.loadIdentity() else {
            say("not_paired")
            return Exit.ok
        }
        let proof = await SecretProof.check(identity)
        switch proof {
        case .accepted: say("paired")
        case .refused(let reason): say("secret_refused \(reason)")
        case .clockSkew: say("unverified clock_skew")
        case .inconclusive(let status): say("unverified status_\(status)")
        }
        say("rules_version: \(MacAgentState.rulesVersion().map { String($0) } ?? "none")")
        if let syncedAt = RuleStore.syncedAt() {
            say("rules_synced_at: \(ISO8601DateFormatter().string(from: syncedAt))")
        } else {
            say("rules_synced_at: never")
        }
        say("child_account: \(MacAgentState.childUser().map { ChildAccount.kind(ofUser: $0).rawValue } ?? "unchecked")")
        return proof == .accepted ? Exit.ok : Exit.failed
    }

    // MARK: - unpair

    /// Clears this Mac's side only (a test-bed and reinstall hook). The parent removes the device in the app.
    private static func unpair() -> Int32 {
        AgentIdentityStore.clear()
        AgentIdentityStore.clearOrphanedSecrets()
        MacAgentState.clear()
        AgentLog.write("event=unpaired_on_command_line")
        say("unpaired")
        return Exit.ok
    }

    private static func say(_ line: String) {
        print(line)
        fflush(stdout)
    }
}
