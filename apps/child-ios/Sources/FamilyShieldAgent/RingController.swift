import Combine
import Foundation

@MainActor
public final class RingController: ObservableObject {
    @Published public private(set) var state: RingState?
    private let backend: RingBackend
    private let store: RingStore
    private let history: RingHistory
    private let reporter: RingAlertReporting
    private let now: () -> Date
    private let monotonic: () -> TimeInterval
    private var restarted = true
    private var lastScheduledIDs: Set<UUID>?
    private var observationTask: Task<Void, Never>?

    public init(backend: RingBackend? = nil, store: RingStore = UserDefaultsRingStore(),
                history: RingHistory = UserDefaultsRingHistory(), reporter: RingAlertReporting? = nil,
                now: @escaping () -> Date = Date.init,
                monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend ?? AlarmKitRingBackend()
        self.store = store
        self.history = history
        self.reporter = reporter ?? RingAlertReporter()
        self.now = now
        self.monotonic = monotonic
        observationTask = Task { [weak self] in
            guard let self else { return }
            let updates = await self.backend.updates()
            for await ids in updates {
                await self.process(scheduledIDs: ids)
            }
        }
    }

    public func start(commandId: String) async -> RingCommandError? {
        guard let id = UUID(uuidString: commandId) else { return .invalidCommand }
        return await start(id)
    }

    public func start(_ id: UUID) async -> RingCommandError? {
        guard !history.contains(id) else { return nil }
        if state?.commandId == id, state?.stopSource == nil { return nil }
        guard backend.available else { return .unsupportedOS }
        guard await backend.requestAuthorization() else { return .authorizationDenied }
        do {
            try await backend.schedule(id)
        } catch {
            return .scheduleFailed
        }
        if let previous = state, previous.commandId != id, previous.stopSource == nil {
            try? await backend.stop(previous.commandId)
        }
        let startedAt = now()
        let next = RingState(commandId: id, startedAt: startedAt,
                             endAt: startedAt.addingTimeInterval(RingPolicy.duration),
                             monotonicStart: monotonic())
        store.save(next)
        state = next
        restarted = false
        lastScheduledIDs = [id]
        return nil
    }

    public func stop(_ trigger: RingTrigger, commandId: UUID? = nil) async {
        guard let current = state, current.stopSource == nil,
              commandId == nil || commandId == current.commandId,
              let source = RingPolicy.stopSource(for: trigger),
              let event = RingPolicy.event(for: trigger) else { return }
        var stopped = current
        stopped.stopSource = source
        state = stopped
        store.save(stopped)
        history.record(current.commandId)
        try? await backend.stop(current.commandId)
        lastScheduledIDs = []
        if await reporter.report(state: event, ringId: current.commandId,
                                 dismissalCount: current.dismissalCount) {
            store.save(nil)
            state = nil
        }
    }

    public func stopForUnpair() async {
        if let current = state ?? store.load() {
            try? await backend.stop(current.commandId)
        }
        store.save(nil)
        state = nil
        lastScheduledIDs = []
        RingAlertReporter.clear()
    }

    public func stopForConsentWithdrawal() async {
        await stopForUnpair()
    }

    public func resume() async {
        lastScheduledIDs = nil
        guard let restored = store.load() else {
            state = nil
            return
        }
        if let source = restored.stopSource {
            state = nil
            let event: RingEventState
            switch source {
            case .pinVerified: event = .pinStopped
            case .parentCommand: event = .parentStopped
            case .timeout: event = .timedOut
            }
            if await reporter.report(state: event, ringId: restored.commandId,
                                     dismissalCount: restored.dismissalCount) {
                store.save(nil)
            }
            return
        }
        state = restored
        restarted = monotonic() < restored.monotonicStart
        if restored.dismissalCount > 0 {
            _ = await reporter.report(state: .childDismissed, ringId: restored.commandId,
                                      dismissalCount: restored.dismissalCount)
        }
        await process(scheduledIDs: await backend.scheduledIDs())
    }

    public func process(scheduledIDs: Set<UUID>) async {
        defer { lastScheduledIDs = scheduledIDs }
        guard let current = state, current.stopSource == nil else { return }
        if RingPolicy.hasTimedOut(current, nowWall: now(), nowMonotonic: monotonic(), restarted: restarted) {
            await stop(.timeout)
            return
        }
        guard !scheduledIDs.contains(current.commandId) else { return }
        do {
            try await backend.schedule(current.commandId)
        } catch {
            return
        }
        if lastScheduledIDs != nil {
            var dismissed = current
            dismissed.dismissalCount += 1
            store.save(dismissed)
            state = dismissed
            _ = await reporter.report(state: .childDismissed, ringId: current.commandId,
                                      dismissalCount: dismissed.dismissalCount)
        }
    }
}
