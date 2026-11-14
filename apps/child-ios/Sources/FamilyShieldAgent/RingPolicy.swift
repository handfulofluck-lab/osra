import Foundation

public enum RingTrigger {
    case pinVerified
    case parentCommand
    case timeout
    case childDismissed
}

public enum RingPolicy {
    public static let duration: TimeInterval = 300

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
        guard nowWall >= state.endAt else { return false }
        return restarted || nowMonotonic - state.monotonicStart >= duration
    }

    public static func dedupeKey(for state: RingEventState, ringId: UUID, dismissalCount: Int) -> String {
        if state == .childDismissed {
            return "ring:\(ringId.uuidString.lowercased()):child_dismissed:\(dismissalCount)"
        }
        return "ring:\(ringId.uuidString.lowercased()):\(state.rawValue)"
    }
}
