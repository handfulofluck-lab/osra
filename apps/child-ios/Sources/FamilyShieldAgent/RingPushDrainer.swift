import Foundation
import os

/// #760: the reduced drain the notification service extension runs when a ring push arrives. A
/// physical-device row proved a priority-5 background push cannot wake a locked/suspended/force-quit
/// iPhone, so the server's ring push is a visible time-sensitive alert; this drain answers it with one
/// short poll of the authenticated command channel, processing only `ring` — every other command is
/// left un-acked for the app's full drain, and the AlarmKit attempt goes through the existing
/// [RingCommandHandling] (the app's [RingController] backend) as a best-effort.
public enum RingPushDrainer {
    private static let logger = Logger(subsystem: "com.osratech.child", category: "RingPush")

    /// The outcome of one drain. Distinct so a verifier can tell "the alarm started" from "the
    /// notification is the fallback surface"; either way the extension shows the localized content.
    public enum Outcome: Equatable {
        /// A `ring` command was acked `ok` after the schedule succeeded.
        case started
        /// Everything else: not paired, the poll failed or held no ring, or the schedule failed. The
        /// notification still shows; a failed schedule is left un-acked so the app's full drain can retry.
        case fallback
    }

    /// The service extension gets the system's short NSE budget, not the app's 30-second wake deadline
    /// (#388): the poll must leave room for the AlarmKit schedule and the acks after it.
    public static let pollTimeoutSeconds: TimeInterval = 8

    /// Polls once with the short timeout and processes at most the first `ring` command. Never throws:
    /// a fetch or schedule failure answers `.fallback`, so it can never suppress the localized
    /// notification content the extension always delivers.
    @discardableResult
    public static func drainNow(client: CommandClient = CommandClient(),
                                ring: RingCommandHandling = LiveRingCommands()) async -> Outcome {
        guard let identity = AgentIdentityStore.load() else { return .fallback }
        let commands: [DeviceCommand]
        do {
            commands = try await client.poll(identity, timeout: pollTimeoutSeconds).commands
        } catch {
            logger.error("ring push poll failed: \(String(describing: error), privacy: .public)")
            return .fallback
        }
        guard let command = commands.first(where: { CommandAction.forType($0.type) == .ring }) else {
            return .fallback
        }
        if await ring.startRing(id: command.id) != nil {
            // The extension must never mark the ring command as failed: a failed AlarmKit schedule
            // here leaves the command for the app's full drain, so the app can ring when it wakes.
            // The localized notification is still delivered as the fallback surface.
            return .fallback
        }
        try? await client.ack(identity, commandId: command.id, ok: true)
        return .started
    }
}
