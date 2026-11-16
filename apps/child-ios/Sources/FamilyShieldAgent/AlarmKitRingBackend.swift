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

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
#endif

@MainActor
public final class AlarmKitRingBackend: RingBackend {
    private let leadTime: TimeInterval
    private let chainInterval: TimeInterval
    private let now: () -> Date
    private let defaults: UserDefaults?
    var activeAlarmIDs: Set<UUID> = []

    public init(leadTime: TimeInterval = 5, chainInterval: TimeInterval = 6,
                now: @escaping () -> Date = Date.init,
                defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) {
        self.leadTime = leadTime
        self.chainInterval = chainInterval
        self.now = now
        self.defaults = defaults
        self.activeAlarmIDs = Self.loadActiveAlarmIDs(from: defaults)
        Self.clearLegacyActiveCommandIDs(from: defaults)
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

    public func schedule(_ id: UUID, until: Date? = nil) async throws {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { throw RingCommandError.unsupportedOS }
        do {
            // Clearing any leftover chain before scheduling is best-effort: on a first ring,
            // or after part of the chain has already fired, the ids do not exist yet.
            try? await cancelAll(for: id, throwOnError: false)
            let alarmIDs = Set([id] + sentinelIDs(for: id, until: until))
            activeAlarmIDs.formUnion(alarmIDs)
            persistActiveAlarmIDs()
            let base = now()
            let dates = chainDates(until: until)
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
            activeAlarmIDs.subtract(alarmIDs(for: id, until: nil))
            persistActiveAlarmIDs()
        }
        #endif
    }

    public func scheduledIDs() async throws -> Set<UUID> {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            do {
                let all = try Set(AlarmManager.shared.alarms.map(\.id))
                return activeAlarmIDs.intersection(all)
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
                        continuation.yield(activeAlarmIDs.intersection(all))
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
    static let activeAlarmIDsKey = "ring.alarmKit.activeAlarmIDs"
    static let legacyActiveCommandIDsKey = "ring.alarmKit.activeCommandIDs"

    private func persistActiveAlarmIDs() {
        let strings = activeAlarmIDs.map { $0.uuidString }
        defaults?.set(strings, forKey: Self.activeAlarmIDsKey)
    }

    private static func loadActiveAlarmIDs(from defaults: UserDefaults?) -> Set<UUID> {
        guard let strings = defaults?.stringArray(forKey: activeAlarmIDsKey) else { return [] }
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }

    private static func clearLegacyActiveCommandIDs(from defaults: UserDefaults?) {
        defaults?.removeObject(forKey: legacyActiveCommandIDsKey)
    }

    func chainDates(until: Date? = nil) -> [TimeInterval] {
        let base = now()
        let maxOffset = min(RingPolicy.duration, until?.timeIntervalSince(base) ?? RingPolicy.duration)
        guard maxOffset > 0 else { return [] }
        let firstOffset = min(leadTime, maxOffset)
        var dates: [TimeInterval] = [firstOffset]
        var offset = firstOffset + chainInterval
        while offset <= maxOffset + .ulpOfOne {
            dates.append(offset)
            offset += chainInterval
        }
        return dates
    }

    func sentinelCount(until: Date? = nil) -> Int {
        let base = now()
        let maxOffset = min(RingPolicy.duration, until?.timeIntervalSince(base) ?? RingPolicy.duration)
        guard leadTime < maxOffset else { return 0 }
        return Int((maxOffset - leadTime) / chainInterval)
    }

    func sentinelIDs(for commandID: UUID, until: Date? = nil) -> [UUID] {
        let count = sentinelCount(until: until)
        guard count > 0 else { return [] }
        return (1...count).map { sentinelID(for: commandID, index: $0) }
    }

    func sentinelID(for commandID: UUID, index: Int) -> UUID {
        var hex = commandID.uuidString
        let suffix = String(format: "%012x", index)
        let prefixEnd = hex.index(hex.startIndex, offsetBy: 24)
        hex = String(hex[..<prefixEnd]) + suffix
        return UUID(uuidString: hex)!
    }

    func alarmIDs(for commandID: UUID, until: Date? = nil) -> Set<UUID> {
        Set([commandID] + sentinelIDs(for: commandID, until: until))
    }
}

extension AlarmKitRingBackend {
    private func cancelAll(for id: UUID, throwOnError: Bool) async throws {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            let ids = alarmIDs(for: id, until: nil)
            let existing = (try? Set(AlarmManager.shared.alarms.map(\.id))) ?? []
            var firstError: Error?
            for alarmID in ids {
                guard existing.contains(alarmID) else { continue }
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
