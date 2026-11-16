import Foundation
import OSLog

#if os(iOS)
import AlarmKit
import AppIntents
import SwiftUI

enum RingAlarmLog {
    private static let logger = Logger(subsystem: "com.osratech.child", category: "Ring")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ operation: String, _ error: Error) {
        let nsError = error as NSError
        logger.error("\(operation, privacy: .public) failed type=\(String(describing: type(of: error)), privacy: .public) code=\(nsError.code, privacy: .public)")
    }
}

@available(iOS 26.0, *)
private struct RingAlarmMetadata: AlarmMetadata {}

@available(iOS 26.0, *)
struct OpenRingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource {
        LocalizedStringResource("ring_dismiss", table: "Localizable", bundle: .module)
    }
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult { .result() }
}
#endif

@MainActor
public final class AlarmKitRingBackend: RingBackend {
    private let leadTime: TimeInterval
    private let chainInterval: TimeInterval
    private let now: () -> Date
    private let defaults: UserDefaults?
    var activeCommandIDs: Set<UUID> = []

    public init(leadTime: TimeInterval = 5, chainInterval: TimeInterval = 6,
                now: @escaping () -> Date = Date.init,
                defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) {
        self.leadTime = leadTime
        self.chainInterval = chainInterval
        self.now = now
        self.defaults = defaults
        self.activeCommandIDs = Self.loadActiveCommandIDs(from: defaults)
    }

    public var available: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    public func requestAuthorization() async -> Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            do {
                let state = try await AlarmManager.shared.requestAuthorization()
                RingAlarmLog.info("authorization state=\(String(describing: state))")
                return state == .authorized
            } catch {
                RingAlarmLog.error("authorization", error)
                return false
            }
        }
        #endif
        return false
    }

    public func schedule(_ id: UUID) async throws {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { throw RingCommandError.unsupportedOS }
        do {
            // Clearing any leftover chain before scheduling is best-effort: on a first ring,
            // or after part of the chain has already fired, the ids do not exist yet.
            try? await cancelAll(for: id, throwOnError: false)
            activeCommandIDs.insert(id)
            persistActiveCommandIDs()
            let base = now()
            let dates = chainDates()
            for (index, offset) in dates.enumerated() {
                let fireDate = base.addingTimeInterval(offset)
                let alarmID = index == 0 ? id : sentinelID(for: id, index: index)
                RingAlarmLog.info("schedule fireDate=\(fireDate.timeIntervalSince1970) offset=\(offset) index=\(index) id=\(alarmID.uuidString)")
                let alert = AlarmPresentation.Alert(
                    title: LocalizedStringResource("ring_alarm_title", table: "Localizable", bundle: .module),
                    stopButton: AlarmButton(text: LocalizedStringResource("ring_alert_ok", table: "Localizable", bundle: .module),
                                            textColor: .white, systemImageName: "checkmark"),
                    secondaryButton: AlarmButton(text: LocalizedStringResource("ring_dismiss", table: "Localizable", bundle: .module),
                                                 textColor: .white, systemImageName: "arrow.up.forward.app"),
                    secondaryButtonBehavior: .custom)
                let attributes = AlarmAttributes<RingAlarmMetadata>(
                    presentation: AlarmPresentation(alert: alert), metadata: RingAlarmMetadata(),
                    tintColor: Color(red: 11 / 255, green: 93 / 255, blue: 87 / 255))
                let configuration: AlarmManager.AlarmConfiguration<RingAlarmMetadata> = .alarm(
                    schedule: .fixed(fireDate), attributes: attributes,
                    secondaryIntent: OpenRingIntent(), sound: .default)
                _ = try await AlarmManager.shared.schedule(id: alarmID, configuration: configuration)
            }
        } catch {
            RingAlarmLog.error("schedule", error)
            throw error
        }
        #else
        throw RingCommandError.unsupportedOS
        #endif
    }

    public func stop(_ id: UUID) async throws {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            try await cancelAll(for: id, throwOnError: true)
            activeCommandIDs.remove(id)
            persistActiveCommandIDs()
        }
        #endif
    }

    public func scheduledIDs() async throws -> Set<UUID> {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            do {
                let all = try Set(AlarmManager.shared.alarms.map(\.id))
                return activeCommandIDs.intersection(all)
            } catch {
                RingAlarmLog.error("scheduledIDs", error)
                throw error
            }
        }
        return []
        #else
        return []
        #endif
    }

    public func updates() async -> AsyncStream<Set<UUID>> {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            let manager = AlarmManager.shared
            return AsyncStream { continuation in
                let task = Task {
                    for await alarms in manager.alarmUpdates {
                        let all = Set(alarms.map(\.id))
                        continuation.yield(activeCommandIDs.intersection(all))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        #endif
        return AsyncStream { $0.finish() }
    }
}

extension AlarmKitRingBackend {
    static let activeCommandIDsKey = "ring.alarmKit.activeCommandIDs"

    private func persistActiveCommandIDs() {
        let strings = activeCommandIDs.map { $0.uuidString }
        defaults?.set(strings, forKey: Self.activeCommandIDsKey)
    }

    private static func loadActiveCommandIDs(from defaults: UserDefaults?) -> Set<UUID> {
        guard let strings = defaults?.stringArray(forKey: activeCommandIDsKey) else { return [] }
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }

    func chainDates() -> [TimeInterval] {
        var dates: [TimeInterval] = [leadTime]
        var offset = leadTime + chainInterval
        while offset <= RingPolicy.duration + .ulpOfOne {
            dates.append(offset)
            offset += chainInterval
        }
        return dates
    }

    func sentinelCount() -> Int {
        guard leadTime < RingPolicy.duration else { return 0 }
        return Int((RingPolicy.duration - leadTime) / chainInterval)
    }

    func sentinelIDs(for commandID: UUID) -> [UUID] {
        (1...sentinelCount()).map { sentinelID(for: commandID, index: $0) }
    }

    func sentinelID(for commandID: UUID, index: Int) -> UUID {
        var hex = commandID.uuidString
        let suffix = String(format: "%012x", index)
        let prefixEnd = hex.index(hex.startIndex, offsetBy: 24)
        hex = String(hex[..<prefixEnd]) + suffix
        return UUID(uuidString: hex)!
    }
}

extension AlarmKitRingBackend {
    private func cancelAll(for id: UUID, throwOnError: Bool) async throws {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            let ids = [id] + sentinelIDs(for: id)
            var firstError: Error?
            for alarmID in ids {
                do {
                    try AlarmManager.shared.cancel(id: alarmID)
                } catch {
                    RingAlarmLog.error("cancel \(alarmID.uuidString)", error)
                    if throwOnError, firstError == nil { firstError = error }
                }
            }
            if let firstError { throw firstError }
        }
        #endif
    }
}
