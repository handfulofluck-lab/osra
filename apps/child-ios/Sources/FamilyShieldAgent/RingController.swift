import Combine
import Foundation

@MainActor
public final class RingController: ObservableObject {
    public static let shared = RingController()
    @Published public private(set) var state: RingState?
    public var requiresPin: Bool {
        guard let state else { return false }
        return !history.contains(state.commandId)
    }
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
    private var operationGeneration = 0
    private let audioPlayer: RingAudioPlaying
    private var schedulingCommandId: UUID?

    public init(backend: RingBackend? = nil, store: RingStore = UserDefaultsRingStore(),
                history: RingHistory = UserDefaultsRingHistory(), reporter: RingAlertReporting? = nil,
                audioPlayer: RingAudioPlaying? = nil,
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
        self.audioPlayer = audioPlayer ?? RingAudioPlayer()
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
        operationGeneration += 1
        let generation = operationGeneration
        guard await backend.requestAuthorization() else { return .authorizationDenied }
        guard generation == operationGeneration else { return nil }
        cancelDeadline()
        let previous = state ?? store.load()
        if let previous, previous.commandId != id, previous.stopSource == nil {
            do {
                try await backend.stop(previous.commandId)
            } catch { }
            await audioPlayer.stop()
            guard generation == operationGeneration else { return nil }
        }
        schedulingCommandId = id
        defer { schedulingCommandId = nil }
        do {
            try await backend.schedule(id, until: nil)
        } catch {
            if generation == operationGeneration {
                await restoreReplacement(previous, generation: generation)
            } else {
                try? await backend.stop(id)
            }
            return .scheduleFailed
        }
        guard generation == operationGeneration else {
            try? await backend.stop(id)
            return nil
        }
        let startedAt = now()
        let next = RingState(commandId: id, startedAt: startedAt,
                             endAt: startedAt.addingTimeInterval(RingPolicy.duration),
                             monotonicStart: monotonic(), bootSession: bootSession())
        store.save(next)
        state = next
        restarted = false
        lastScheduledIDs = [id]
        await audioPlayer.start()
        armDeadline()
        return nil
    }

    private func restoreReplacement(_ previous: RingState?, generation: Int) async {
        guard let previous else {
            store.save(nil)
            state = nil
            return
        }
        var restored = previous
        if restored.stopSource != nil && !history.contains(restored.commandId) {
            restored.stopSource = nil
        }
        state = restored
        store.save(restored)
        if restored.stopSource == nil {
            do {
                if try await !backend.scheduledIDs().contains(restored.commandId) {
                    schedulingCommandId = restored.commandId
                    defer { schedulingCommandId = nil }
                    try await backend.schedule(restored.commandId, until: restored.endAt)
                }
                guard generation == operationGeneration, state?.commandId == restored.commandId else {
                    if state?.commandId != restored.commandId { try? await backend.stop(restored.commandId) }
                    return
                }
                lastScheduledIDs = [restored.commandId]
            } catch {
                lastScheduledIDs = nil
            }
        } else {
            lastScheduledIDs = []
        }
        armDeadline()
        if restored.stopSource == nil {
            await audioPlayer.start()
        }
    }

    @discardableResult
    public func stop(_ trigger: RingTrigger, commandId: UUID? = nil) async -> RingCommandError? {
        guard let current = state ?? store.load(), commandId == nil || commandId == current.commandId else {
            return commandId == nil ? nil : .invalidCommand
        }
        if let pending = current.stopSource {
            guard pending == RingPolicy.stopSource(for: trigger) else { return nil }
            return await resume()
        }
        guard let source = RingPolicy.stopSource(for: trigger),
              let event = RingPolicy.event(for: trigger) else { return nil }
        operationGeneration += 1
        let generation = operationGeneration
        var stopped = current
        stopped.stopSource = source
        state = stopped
        store.save(stopped)
        cancelDeadline()
        do {
            try await backend.stop(current.commandId)
        } catch {
            guard generation == operationGeneration else { return .stopFailed }
            state = current
            store.save(current)
            armDeadline()
            return .stopFailed
        }
        guard generation == operationGeneration else { return nil }
        history.record(current.commandId)
        lastScheduledIDs = []
        state = stopped
        store.save(stopped)
        #if os(iOS)
        RingNotifier.cancel()
        #endif
        await audioPlayer.stop()
        await report(event, for: stopped, generation: generation)
        return nil
    }

    public func stopForUnpair() async {
        operationGeneration += 1
        let generation = operationGeneration
        cancelDeadline()
        guard let current = state ?? store.load() else {
            if generation == operationGeneration {
                store.save(nil)
                state = nil
                RingAlertReporter.clear()
                UserDefaultsRingHistory.clear()
                #if os(iOS)
                RingNotifier.cancel()
                #endif
            }
            return
        }
        do {
            try await backend.stop(current.commandId)
            guard generation == operationGeneration else { return }
            store.save(nil)
            state = nil
            lastScheduledIDs = []
            history.remove(current.commandId)
            RingAlertReporter.clear()
            UserDefaultsRingHistory.clear()
            #if os(iOS)
            RingNotifier.cancel()
            #endif
            await audioPlayer.stop()
        } catch {
            if generation == operationGeneration {
                state = current
                store.save(current)
            }
        }
    }

    public func stopForConsentWithdrawal() async {
        await stopForUnpair()
    }

    @discardableResult
    public func resume() async -> RingCommandError? {
        operationGeneration += 1
        let generation = operationGeneration
        lastScheduledIDs = nil
        guard let restored = store.load() else {
            state = nil
            return nil
        }
        state = restored
        restarted = restored.bootSession.map { $0 != bootSession() } ?? (monotonic() < restored.monotonicStart)
        if let source = restored.stopSource {
            let event = event(for: source)
            if history.contains(restored.commandId) {
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
                await audioPlayer.stop()
                await report(event, for: restored, generation: generation)
                return nil
            }
            var active = restored
            active.stopSource = nil
            state = active
            store.save(active)
            await audioPlayer.start()
            armDeadline()
            do {
                if try await !backend.scheduledIDs().contains(restored.commandId) {
                    history.record(restored.commandId)
                    cancelDeadline()
                    #if os(iOS)
                    RingNotifier.cancel()
                    #endif
                    await report(event, for: restored, generation: generation)
                }
            } catch {
                if generation == operationGeneration { return .stopFailed }
            }
            return nil
        }
        if restarted {
            await timeoutAfterRestart(restored)
        } else {
            await audioPlayer.start()
            armDeadline()
            await drainReports()
            do {
                await process(scheduledIDs: try await backend.scheduledIDs())
            } catch { }
        }
        return nil
    }

    private func event(for source: RingStopSource) -> RingEventState {
        switch source {
        case .pinVerified: return .pinStopped
        case .parentCommand: return .parentStopped
        case .timeout: return .timedOut
        }
    }

    private func trigger(for state: RingEventState) -> RingTrigger? {
        switch state {
        case .pinStopped: return .pinVerified
        case .parentStopped: return .parentCommand
        case .timedOut: return .timeout
        case .childDismissed: return nil
        }
    }

    private func report(_ event: RingEventState, for current: RingState, generation: Int? = nil) async {
        let expectedGeneration = generation ?? operationGeneration
        let afterRestart = restarted || (event == .timedOut && current.bootSession.map { $0 != bootSession() } == true)
        let outcome = await reporter.report(state: event, ringId: current.commandId,
                                            dismissalCount: current.dismissalCount, afterRestart: afterRestart)
        guard expectedGeneration == operationGeneration, state?.commandId == current.commandId else { return }
        if event == .timedOut, case .resume(let seconds) = outcome {
            await applyResume(current, seconds: seconds, generation: expectedGeneration)
            return
        }
        guard outcome == .delivered, event != .childDismissed else { return }
        if current.stopSource == nil, let trigger = trigger(for: event) {
            await stop(trigger, commandId: current.commandId)
        } else {
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
            await applyResume(current, seconds: seconds, generation: operationGeneration)
        case .pending:
            var pending = current
            pending.endAt = RingPolicy.capEndAt(now().addingTimeInterval(RingPolicy.duration), startedAt: current.startedAt)
            pending.monotonicStart = monotonic()
            state = pending
            restarted = false
            armDeadline()
        }
    }

    private func applyResume(_ current: RingState, seconds: Int, generation: Int) async {
        guard generation == operationGeneration, state?.commandId == current.commandId else { return }
        let cappedEndAt = RingPolicy.capEndAt(now().addingTimeInterval(TimeInterval(seconds)), startedAt: current.startedAt)
        guard cappedEndAt > now() else {
            // The server asked us to resume, but the original 5-minute cap has already passed.
            cancelDeadline()
            try? await backend.stop(current.commandId)
            history.record(current.commandId)
            store.save(nil)
            state = nil
            lastScheduledIDs = []
            await audioPlayer.stop()
            return
        }
        history.remove(current.commandId)
        var resumed = current
        resumed.stopSource = nil
        resumed.endAt = cappedEndAt
        resumed.monotonicStart = monotonic() - (RingPolicy.duration - TimeInterval(seconds))
        store.save(resumed)
        state = resumed
        restarted = false
        await audioPlayer.start()
        armDeadline()
        do {
            if try await !backend.scheduledIDs().contains(current.commandId) {
                schedulingCommandId = current.commandId
                defer { schedulingCommandId = nil }
                try await backend.schedule(current.commandId, until: resumed.endAt)
            }
            guard generation == operationGeneration, state?.commandId == current.commandId else {
                if state?.commandId != current.commandId { try? await backend.stop(current.commandId) }
                return
            }
            lastScheduledIDs = [current.commandId]
        } catch {
            if generation == operationGeneration { lastScheduledIDs = nil }
        }
    }

    private func drainReports() async {
        for event in reporter.pendingEvents() {
            let generation = operationGeneration
            let outcome = await reporter.report(state: event.state, ringId: event.ringId,
                                                dismissalCount: event.dismissalCount, afterRestart: event.afterRestart)
            if outcome == .pending { break }
            if event.state == .timedOut, case .resume(let seconds) = outcome,
               generation == operationGeneration,
               let current = state, current.commandId == event.ringId {
                await applyResume(current, seconds: seconds, generation: generation)
            } else if outcome == .delivered, event.state != .childDismissed,
                      generation == operationGeneration, state?.commandId == event.ringId {
                if state?.stopSource == nil, let trigger = trigger(for: event.state) {
                    await stop(trigger, commandId: event.ringId)
                } else {
                    store.save(nil)
                    state = nil
                }
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
        let generation = operationGeneration
        defer {
            if generation == operationGeneration { lastScheduledIDs = scheduledIDs }
        }
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
        guard schedulingCommandId != current.commandId else { return }
        guard !scheduledIDs.contains(current.commandId) else { return }
        if scheduledIDs.isEmpty && !restarted {
            await rearmAndReportDismissal(current, generation: generation)
        } else {
            await rearm(current, generation: generation)
        }
    }

    private func rearm(_ current: RingState, generation: Int) async {
        schedulingCommandId = current.commandId
        defer { schedulingCommandId = nil }
        do {
            try await backend.schedule(current.commandId, until: current.endAt)
        } catch {
            return
        }
        guard generation == operationGeneration,
              state?.commandId == current.commandId, state?.stopSource == nil else {
            if state?.commandId != current.commandId { try? await backend.stop(current.commandId) }
            return
        }
        armDeadline()
        await audioPlayer.start()
    }

    private func rearmAndReportDismissal(_ current: RingState, generation: Int) async {
        schedulingCommandId = current.commandId
        defer { schedulingCommandId = nil }
        do {
            try await backend.schedule(current.commandId, until: current.endAt)
        } catch {
            return
        }
        guard generation == operationGeneration,
              state?.commandId == current.commandId, state?.stopSource == nil else {
            if state?.commandId != current.commandId { try? await backend.stop(current.commandId) }
            return
        }
        var dismissed = current
        dismissed.dismissalCount += 1
        dismissed.endAt = RingPolicy.capEndAt(dismissed.endAt, startedAt: dismissed.startedAt)
        store.save(dismissed)
        state = dismissed
        _ = await reporter.report(state: .childDismissed, ringId: current.commandId,
                                  dismissalCount: dismissed.dismissalCount)
        armDeadline()
        await audioPlayer.start()
    }
}
