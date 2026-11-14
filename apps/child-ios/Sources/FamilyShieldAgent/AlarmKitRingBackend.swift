import Foundation

#if os(iOS)
import AlarmKit
import AppIntents
import SwiftUI

@available(iOS 26.0, *)
private struct RingAlarmMetadata: AlarmMetadata {}

@available(iOS 26.0, *)
struct OpenRingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: L10n.tr("ring_dismiss"))
    }
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult { .result() }
}
#endif

@MainActor
public final class AlarmKitRingBackend: RingBackend {
    public init() {}

    public var available: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    public func requestAuthorization() async -> Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        }
        #endif
        return false
    }

    public func schedule(_ id: UUID) async throws {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { throw RingCommandError.unsupportedOS }
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: L10n.tr("ring_alarm_title")),
            stopButton: AlarmButton(text: LocalizedStringResource(stringLiteral: L10n.tr("ring_alert_ok")),
                                    textColor: .white, systemImageName: "checkmark"),
            secondaryButton: AlarmButton(text: LocalizedStringResource(stringLiteral: L10n.tr("ring_dismiss")),
                                         textColor: .white, systemImageName: "arrow.up.forward.app"),
            secondaryButtonBehavior: .custom)
        let attributes = AlarmAttributes<RingAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert), metadata: RingAlarmMetadata(),
            tintColor: Color(red: 11 / 255, green: 93 / 255, blue: 87 / 255))
        let configuration: AlarmManager.AlarmConfiguration<RingAlarmMetadata> = .alarm(
            schedule: .fixed(Date()), attributes: attributes,
            secondaryIntent: OpenRingIntent(), sound: .default)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        #else
        throw RingCommandError.unsupportedOS
        #endif
    }

    public func stop(_ id: UUID) async throws {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            try AlarmManager.shared.cancel(id: id)
        }
        #endif
    }

    public func scheduledIDs() async -> Set<UUID> {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return Set((try? AlarmManager.shared.alarms.map(\.id)) ?? [])
        }
        #endif
        return []
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
