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
    private let now: () -> Date

    public init(leadTime: TimeInterval = 5, now: @escaping () -> Date = Date.init) {
        self.leadTime = leadTime
        self.now = now
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
            let fireDate = now().addingTimeInterval(leadTime)
            RingAlarmLog.info("schedule fireDate=\(fireDate.timeIntervalSince1970, privacy: .public) leadTime=\(leadTime, privacy: .public)")
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
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
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
            do {
                try AlarmManager.shared.cancel(id: id)
            } catch {
                RingAlarmLog.error("cancel", error)
                throw error
            }
        }
        #endif
    }

    public func scheduledIDs() async throws -> Set<UUID> {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            do {
                return try Set(AlarmManager.shared.alarms.map(\.id))
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
                        continuation.yield(Set(alarms.map(\.id)))
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
