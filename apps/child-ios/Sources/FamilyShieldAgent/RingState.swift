import Foundation

public struct RingState: Codable, Equatable {
    public var commandId: UUID
    public var startedAt: Date
    public var endAt: Date
    public var monotonicStart: TimeInterval
    public var stopSource: RingStopSource?
    public var dismissalCount: Int

    public init(commandId: UUID, startedAt: Date, endAt: Date, monotonicStart: TimeInterval,
                stopSource: RingStopSource? = nil, dismissalCount: Int = 0) {
        self.commandId = commandId
        self.startedAt = startedAt
        self.endAt = endAt
        self.monotonicStart = monotonicStart
        self.stopSource = stopSource
        self.dismissalCount = dismissalCount
    }
}

public enum RingStopSource: String, Codable {
    case pinVerified
    case parentCommand
    case timeout
}

public enum RingEventState: String, Codable {
    case childDismissed = "child_dismissed"
    case pinStopped = "pin_stopped"
    case parentStopped = "parent_stopped"
    case timedOut = "timed_out"
}
