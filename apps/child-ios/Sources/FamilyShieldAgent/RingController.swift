import Combine
import Foundation

@MainActor
public final class RingController: ObservableObject {
    public static let shared = RingController()
    @Published public private(set) var state: RingState?
    private let backend: RingBackend
    private let store: RingStore
    private let history: RingHistory
    private let reporter: RingAlertReporting
    private let now: () -> Date
    private let monotonic: () -> TimeInterval
    private let bootSession: () -> TimeInterval?
    private let sleep: (TimeInterval) async throws -> Void
    private var restarted = true
    private var lastScheduledIDs: Set<UUID>?
    private var observationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var deadlineGeneration = 0

    public init(backend: RingBackend? = nil, store: RingStore = UserDefaultsRingStore(),
                history: RingHistory = UserDefaultsRingHistory(), reporter: RingAlertReporting? = nil,
                now: @escaping () -> Date = Date.init,
                monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                bootSession: @escaping () -> TimeInterval? = { RingBootSession.current() },
                sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
                    try await ContinuousClock().sleep(for: .seconds(seconds))
                }) {
        self.backend = backend ?? AlarmKitRingBackend()
        self.store = store
        self.history = history
        self.reporter = reporter ?? RingAlertReporter()
        self.now = now
        self.monotonic = monotonic
        self.bootSession = bootSession
        self.sleep = sleep
        observationTask = Task { [weak self] in
            guard let self else { return }
            let updates = await self.backend.updates()
            for await ids in updates {
                await self.process(scheduledIDs: ids)
            }
        }
    }

    public func enterBackground() async {
        do {
            await process(scheduledIDs: try await backend.scheduledIDs())
        } catch { }
    }

    public func start(commandId: String) async -> RingCommandError? {
        guard let id = UUID(uuidString: commandId) else { return .invalidCommand }
        return await start(id)
    }

    public func start(_ id: UUID) async -> RingCommandError? {
        await drainReports()
        guard !history.contains(id) else { return nil }
        if let current = state ?? store.load(), current.commandId == id, current.stopSource == nil {
            state = current
            _ = await resume()
            return nil
        }
        guard backend.available else { return .unsupportedOS }
        guard await backend.requestAuthorization() else { return .authorizationDenied }
        cancelDeadline()
        if let previous = state, previous.commandId != id {
            do {
                try await backend.stop(previous.commandId)
            } catch {
                return .scheduleFailed
            }
        }
        do {
            try await backend.schedule(id)
        } catch {
            return .scheduleFailed
        }
        let startedAt = now()
        let next = RingState(commandId: id, startedAt: startedAt,
                             endAt: startedAt.addingTimeInterval(RingPolicy.duration),
                             monotonicStart: monotonic(), bootSession: bootSession())
        store.save(next)
        state = next
        restarted = false
        lastScheduledIDs = [id]
        armDeadline()
        return nil
    }

    @discardableResult
    public func stop(_ trigger: RingTrigger, commandId: UUID? = nil) async -> RingCommandError? {
        guard let current = state ?? store.load(), commandId == nil || commandId == current.commandId else { return nil }
        if let pending = current.stopSource {
            guard pending == RingPolicy.stopSource(for: trigger) else { return nil }
            return await resume()
        }
        guard let source = RingPolicy.stopSource(for: trigger),
              let event = RingPolicy.event(for: trigger) else { return nil }
        var stopped = current
        stopped.stopSource = source
        state = stopped
        store.save(stopped)
        history.record(current.commandId)
        cancelDeadline()
        do {
            try await backend.stop(current.commandId)
        } catch {
            return .stopFailed
        }
        #if os(iOS)
        RingNotifier.cancel()
        #endif
        lastScheduledIDs = []
        await report(event, for: stopped)
        return nil
    }

    public func stopForUnpair() async {
        guard let current = state ?? store.load() else {
            store.save(nil)
            state = nil
            RingAlertReporter.clear()
            UserDefaultsRingHistory.clear()
            #if os(iOS)
            RingNotifier.cancel()
            #endif
            return
        }
        do {
            try await backend.stop(current.commandId)
            store.save(nil)
            state = nil
            lastScheduledIDs = []
            RingAlertReporter.clear()
            UserDefaultsRingHistory.clear()
            #if os(iOS)
            RingNotifier.cancel()
            #endif
        } catch {
            state = current
        }
    }

    public func stopForConsentWithdrawal() async {
        await stopForUnpair()
    }

    @discardableResult
    public func resume() async -> RingCommandError? {
        lastScheduledIDs = nil
        guard let restored = store.load() else {
            state = nil
            return nil
        }
        state = restored
        restarted = restored.bootSession.map { $0 != bootSession() } ?? (monotonic() < restored.monotonicStart)
        if let source = restored.stopSource {
            cancelDeadline()
            do {
                if try await backend.scheduledIDs().contains(restored.commandId) {
                    try await backend.stop(restored.commandId)
                }
            } catch {
                return .stopFailed
            }
            #if os(iOS)
            RingNotifier.cancel()
            #endif
            let event: RingEventState
            switch source {
            case .pinVerified: event = .pinStopped
            case .parentCommand: event = .parentStopped
            case .timeout: event = .timedOut
            }
            await report(event, for: restored)
            if state?.stopSource != nil { state = nil }
            return nil
        }
        armDeadline()
        await drainReports()
        do {
            await process(scheduledIDs: try await backend.scheduledIDs())
        } catch { }
        return nil
    }

    private func report(_ event: RingEventState, for current: RingState) async {
        let afterRestart = restarted || (event == .timedOut && current.bootSession.map { $0 != bootSession() } == true)
        let outcome = await reporter.report(state: event, ringId: current.commandId,
                                            dismissalCount: current.dismissalCount, afterRestart: afterRestart)
        if event == .timedOut, case .resume(let seconds) = outcome {
            await applyResume(current, seconds: seconds)
            return
        }
        if outcome == .delivered {
            store.save(nil)
            state = nil
        }
    }

    private func timeoutAfterRestart(_ current: RingState) async {
        let outcome = await reporter.report(state: .timedOut, ringId: current.commandId,
                                            dismissalCount: current.dismissalCount, afterRestart: true)
        switch outcome {
        case .delivered:
            await stop(.timeout)
        case .resume(let seconds):
            await applyResume(current, seconds: seconds)
        case .pending:
            var pending = current
            pending.endAt = now().addingTimeInterval(RingPolicy.duration)
            pending.monotonicStart = monotonic()
            state = pending
            restarted = false
            armDeadline()
        }
    }

    private func applyResume(_ current: RingState, seconds: Int) async {
        history.remove(current.commandId)
        var resumed = current
        resumed.stopSource = nil
        resumed.endAt = now().addingTimeInterval(TimeInterval(seconds))
        resumed.monotonicStart = monotonic() - (RingPolicy.duration - TimeInterval(seconds))
        store.save(resumed)
        state = resumed
        restarted = false
        armDeadline()
        do {
            if try await !backend.scheduledIDs().contains(current.commandId) {
                try await backend.schedule(current.commandId)
            }
            lastScheduledIDs = [current.commandId]
        } catch {
            lastScheduledIDs = nil
        }
    }

    private func drainReports() async {
        for event in reporter.pendingEvents() {
            let outcome = await reporter.report(state: event.state, ringId: event.ringId,
                                                dismissalCount: event.dismissalCount, afterRestart: event.afterRestart)
            if outcome == .pending { break }
            if event.state == .timedOut, case .resume(let seconds) = outcome,
               let current = state, current.commandId == event.ringId {
                await applyResume(current, seconds: seconds)
            } else if outcome == .delivered, event.state != .childDismissed,
                      state?.commandId == event.ringId {
                store.save(nil)
                state = nil
            }
        }
    }

    private func cancelDeadline() {
        deadlineGeneration += 1
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func armDeadline() {
        cancelDeadline()
        guard let current = state, current.stopSource == nil else { return }
        let elapsed = monotonic() - current.monotonicStart
        let remaining = restarted
            ? max(0, current.endAt.timeIntervalSince(now()))
            : max(0, RingPolicy.duration - elapsed)
        let id = current.commandId
        let generation = deadlineGeneration
        deadlineTask = Task { [weak self] in
            do {
                try await self?.sleep(remaining)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            guard generation == self.deadlineGeneration,
                  let current = self.state, current.commandId == id, current.stopSource == nil else { return }
            guard RingPolicy.hasTimedOut(current, nowWall: self.now(), nowMonotonic: self.monotonic(),
                                         restarted: self.restarted) else {
                self.armDeadline()
                return
            }
            if self.restarted {
                await self.timeoutAfterRestart(current)
            } else {
                await self.stop(.timeout)
            }
        }
    }

    public func process(scheduledIDs: Set<UUID>) async {
        defer { lastScheduledIDs = scheduledIDs }
        await drainReports()
        guard let current = state, current.stopSource == nil else { return }
        if RingPolicy.hasTimedOut(current, nowWall: now(), nowMonotonic: monotonic(), restarted: restarted) {
            if restarted {
                await timeoutAfterRestart(current)
            } else {
                await stop(.timeout)
            }
            return
        }
        guard !scheduledIDs.contains(current.commandId) else { return }
        do {
            try await backend.schedule(current.commandId)
        } catch {
            return
        }
        guard state?.commandId == current.commandId, state?.stopSource == nil else {
            try? await backend.stop(current.commandId)
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
