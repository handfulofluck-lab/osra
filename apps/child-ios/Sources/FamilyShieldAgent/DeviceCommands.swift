import Foundation
import os

/// The device command queue, as the Android agent drains it (5.5 PR D, #372): `GET /v1/devices/:id/commands?ack=1`
/// with the device token, then `POST /v1/devices/:id/commands/:commandId/ack` for each. A push only wakes the
/// app (`{"w":"1"}`, no command in it, #319); the command itself comes over this authenticated channel.
public struct DeviceCommand: Decodable, Equatable {
    public var id: String
    public var type: String
}

/// What the iOS agent does with a command. iOS enforces through Screen Time, so it handles what changes the
/// rules and refuses the rest out loud: a parent must see "failed", never a silent "delivered".
public enum CommandAction: Equatable {
    /// Fetch the rules again; a withdrawn consent then answers 428 and clears everything.
    case syncRules
    /// A fresh point for the parent's map, uploaded before the ack (5.5 PR E).
    case locateNow
    /// Not something this agent can do; acked `failed` with the reason.
    case unsupported

    public static func forType(_ type: String) -> CommandAction {
        switch type {
        case "rules_updated", "consent_revoked", "consent_granted": return .syncRules
        case "locate_now": return .locateNow
        default: return .unsupported
        }
    }
}

/// One answer to the poll: the commands, and whether the server still holds this device's push token.
public struct CommandPoll: Equatable {
    public var commands: [DeviceCommand]
    /// `X-Push-Token` (#383): false only on an explicit `none`. An older server sends no header, and then
    /// nothing changes.
    public var serverHasPushToken: Bool

    public init(commands: [DeviceCommand], serverHasPushToken: Bool = true) {
        self.commands = commands
        self.serverHasPushToken = serverHasPushToken
    }
}

public struct CommandClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public enum CommandError: Error, Equatable {
        case httpError(status: Int)
        case unusableResponse
    }

    /// Claims the pending commands (`ack=1`: they come back until acked, as Android's ack-capable poll).
    public func poll(_ identity: AgentIdentity) async throws -> CommandPoll {
        var components = URLComponents(url: devicesURL(identity).appendingPathComponent("commands"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "ack", value: "1")]
        guard let url = components?.url else { throw CommandError.unusableResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(identity.deviceToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CommandError.httpError(status: status) }
        guard let commands = try? JSONDecoder().decode([DeviceCommand].self, from: data) else {
            throw CommandError.unusableResponse
        }
        let pushToken = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Push-Token")
        return CommandPoll(commands: commands, serverHasPushToken: pushToken != "none")
    }

    /// Reports a command's outcome; `detail` says why when it failed.
    public func ack(_ identity: AgentIdentity, commandId: String, ok: Bool, detail: [String: String] = [:]) async throws {
        var request = URLRequest(url: devicesURL(identity).appendingPathComponent("commands")
            .appendingPathComponent(commandId).appendingPathComponent("ack"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(identity.deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["status": ok ? "ok" : "failed"]
        if !detail.isEmpty { body["detail"] = detail }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CommandError.httpError(status: status) }
    }

    private func devicesURL(_ identity: AgentIdentity) -> URL {
        identity.apiBaseURL.appendingPathComponent("v1/devices").appendingPathComponent(identity.deviceId)
    }
}

/// One drain of the command queue: on a wake push, and when the app opens.
/// Answers a `locate_now`; nil means no ack. The live one is [LocationController]; tests use a fake.
public protocol LocateNowHandling {
    func locateNow() async -> LocateAck?
}

public struct LiveLocateNow: LocateNowHandling {
    public init() {}
    public func locateNow() async -> LocateAck? { await LocationController.shared.locateNow() }
}

public enum CommandDrainer {
    private static let logger = Logger(subsystem: "dev.familyshield.agent", category: "Commands")

    public struct Result: Equatable {
        public var handled: [String] = []
        public var refused: [String] = []
        /// The poll answered 428: consent was withdrawn, and the rules were synced (and so cleared).
        public var consentWithdrawn = false
        /// The poll said the server holds no push token, and the stored one was sent again (#383).
        public var pushTokenResent = false
    }

    @discardableResult
    public static func drainNow(client: CommandClient = CommandClient(),
                                tokenSession: URLSession = .shared,
                                locator: LocateNowHandling = LiveLocateNow(),
                                sync: () async -> RuleSyncer.Outcome = { await RuleSyncer.syncNow() }) async -> Result {
        var result = Result()
        guard let identity = AgentIdentityStore.load() else { return result }
        let commands: [DeviceCommand]
        do {
            let poll = try await client.poll(identity)
            commands = poll.commands
            if !poll.serverHasPushToken {
                // #383: without a token on file the server cannot wake this phone; heal it on this drain.
                let resent = await PushTokenRegistrar.resendAfterServerCleared(session: tokenSession)
                result.pushTokenResent = resent == .uploaded
            }
        } catch CommandClient.CommandError.httpError(status: 428) {
            // ADR-0008 §2b: monitoring is paused. The rules endpoint answers 428 too, which clears them.
            result.consentWithdrawn = true
            _ = await sync()
            return result
        } catch {
            logger.error("command poll failed: \(String(describing: error), privacy: .public)")
            return result
        }
        var firstSync: RuleSyncer.Outcome?
        var located = false
        var locateAck: LocateAck?
        for command in commands {
            switch CommandAction.forType(command.type) {
            case .syncRules:
                // Several rules_updated in one drain cost one fetch.
                let outcome: RuleSyncer.Outcome
                if let earlier = firstSync {
                    outcome = earlier
                } else {
                    outcome = await sync()
                    firstSync = outcome
                }
                let ok: Bool
                switch outcome {
                case .synced, .consentWithdrawn: ok = true
                case .notPaired, .failed: ok = false
                }
                try? await client.ack(identity, commandId: command.id, ok: ok,
                                      detail: ok ? [:] : ["reason": "rule_sync_failed"])
                result.handled.append(command.type)
            case .locateNow:
                // Several in one drain share one fix and one upload.
                if !located {
                    locateAck = await locator.locateNow()
                    located = true
                }
                switch locateAck {
                case .ok(let fix)?:
                    try? await client.ack(identity, commandId: command.id, ok: true, detail: ["fix": fix])
                case .failed(let reason)?:
                    try? await client.ack(identity, commandId: command.id, ok: false, detail: ["reason": reason])
                case nil:
                    break // the point was not stored: no ack, so the server offers the command again in 120 s
                }
                result.handled.append(command.type)
            case .unsupported:
                try? await client.ack(identity, commandId: command.id, ok: false,
                                      detail: ["reason": "unsupported_on_ios", "type": command.type])
                result.refused.append(command.type)
            }
        }
        return result
    }
}

extension CommandDrainer {
    /// iOS gives a woken app about 30 seconds to call its completion handler, and repeated overruns make it
    /// hold back later wakes. A drain chains a poll, a rule sync and the acks, each with a 30-second timeout,
    /// so the wake path drains under this deadline instead (Claude's note 2 on #382).
    public static let wakeDeadlineSeconds: Double = 25

    /// Drains, but answers by the deadline: the drain's result, or nil once `seconds` pass first. The drain is
    /// then cancelled, and it answers nil even if the work ignores the cancellation. A drain that answers
    /// first cancels the timer (Claude on #388).
    public static func drain(within seconds: Double = wakeDeadlineSeconds,
                             _ work: @escaping () async -> Result = { await drainNow() }) async -> Result? {
        let first = FirstAnswer<Result?>()
        return await withCheckedContinuation { continuation in
            first.continuation = continuation
            let drain = Task { await work() }
            let timer = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return // cancelled: the drain answered first
                }
                drain.cancel()
                first.answer(nil)
            }
            Task {
                let result = await drain.value
                timer.cancel()
                first.answer(result)
            }
        }
    }
}

/// Resumes a continuation with whichever answer comes first, once.
private final class FirstAnswer<T> {
    private let lock = NSLock()
    private var answered = false
    var continuation: CheckedContinuation<T, Never>?

    func answer(_ value: T) {
        lock.lock()
        guard !answered, let continuation else { lock.unlock(); return }
        answered = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}
