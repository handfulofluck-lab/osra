import Foundation

public enum RingTrigger {
    case pinVerified
    case parentCommand
    case timeout
    case childDismissed
}

public enum RingPolicy {
    public static let duration: TimeInterval = 300
    /// A re-arm cancels and re-adds the alarm chain, so one physical dismissal can surface as more than one
    /// snapshot. The controller accepts at most one dismissal report in this interval; the chain itself is
    /// spaced six seconds apart, so a real second dismissal still arrives after it.
    public static let minimumDismissalInterval: TimeInterval = 6

    public static func event(for trigger: RingTrigger) -> RingEventState? {
        switch trigger {
        case .pinVerified: return .pinStopped
        case .parentCommand: return .parentStopped
        case .timeout: return .timedOut
        case .childDismissed: return nil
        }
    }

    public static func stopSource(for trigger: RingTrigger) -> RingStopSource? {
        switch trigger {
        case .pinVerified: return .pinVerified
        case .parentCommand: return .parentCommand
        case .timeout: return .timeout
        case .childDismissed: return nil
        }
    }

    public static func hasTimedOut(_ state: RingState, nowWall: Date,
                                   nowMonotonic: TimeInterval, restarted: Bool) -> Bool {
        if restarted { return nowWall >= state.endAt }
        return nowMonotonic - state.monotonicStart >= duration
    }

    /// The absolute wall-clock cap for any ring: five minutes after the server command arrived.
    public static func capEndAt(_ date: Date, startedAt: Date) -> Date {
        min(date, startedAt.addingTimeInterval(duration))
    }

    public static func dedupeKey(for state: RingEventState, ringId: UUID, dismissalCount: Int) -> String {
        if state == .childDismissed {
            return "ring:\(ringId.uuidString.lowercased()):child_dismissed:\(dismissalCount)"
        }
        return "ring:\(ringId.uuidString.lowercased()):\(state.rawValue)"
    }
}
