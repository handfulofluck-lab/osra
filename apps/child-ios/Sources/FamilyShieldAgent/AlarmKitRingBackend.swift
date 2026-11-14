import Foundation

#if os(iOS)
import AlarmKit

@available(iOS 26.0, *)
private struct RingAlarmMetadata: AlarmMetadata {}
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
            stopButton: AlarmButton(text: LocalizedStringResource(stringLiteral: L10n.tr("ring_dismiss")),
                                    textColor: .white, systemImageName: "xmark"))
        let attributes = AlarmAttributes<RingAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert), metadata: RingAlarmMetadata(), tintColor: .accentColor)
        let configuration: AlarmManager.AlarmConfiguration<RingAlarmMetadata> = .alarm(
            schedule: .fixed(Date()), attributes: attributes, sound: .default)
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
