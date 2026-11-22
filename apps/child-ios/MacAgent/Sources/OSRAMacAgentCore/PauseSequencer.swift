import Foundation

/// The accepted/applied split, as pure logic, so every ordering rule in #990's contract is testable without a
/// signed Mac.
///
/// Three events, and nothing else may move the state:
///  * **accept** — the parent asked for `pause` or `resume`. The daemon assigns the next `op`, records `desired`,
///    and reports `pending`. It never reports `applied` here, whatever the filter is doing.
///  * **confirm** — the filter says it published and applied operation `op` at policy `version`. Only the
///    operation matching the current `desired` counts; anything older is stale and discarded, because applying a
///    late pause after a newer resume is how a child's Mac goes offline after a parent turned it back on.
///  * **restart** — the daemon comes up and must reconcile: `desired` wins, so a Mac is never left paused by a
///    crash, and a resume accepted while the filter was down is applied now.
public enum PauseSequencer {
    public enum Outcome: Equatable {
        /// Taken, not confirmed. The parent may read "waiting", never "done".
        case pending(op: Int)
        /// Confirmed by the filter at this operation and policy version.
        case applied(op: Int, version: Int)
        /// A confirmation for an operation the parent has already superseded. Discarded, and logged by the caller.
        case stale(op: Int, supersededBy: Int)
    }

    public struct Transition: Equatable {
        public var state: PauseState
        public var outcome: Outcome
    }

    /// The parent asked for something. `filterRunning` is recorded for the log line only: an operation is
    /// accepted either way, because refusing a resume is the one failure that leaves the Mac paused with no way
    /// back (Codex, #990 `7075057587`).
    public static func accept(_ desired: PauseState.Desired,
                              current: PauseState?,
                              filterRunning: Bool,
                              now: Date = Date()) -> Transition {
        _ = filterRunning
        let next = PauseState(op: (current?.op ?? 0) + 1,
                              appliedOp: current?.appliedOp ?? 0,
                              desired: desired,
                              updatedAt: now)
        return Transition(state: next, outcome: .pending(op: next.op))
    }

    /// The filter confirmed `op`. Stale confirmations are discarded rather than applied.
    public static func confirm(op: Int, version: Int, current: PauseState) -> Transition {
        guard op == current.op else {
            let superseded = op < current.op
            return Transition(state: current,
                              outcome: superseded ? .stale(op: op, supersededBy: current.op) : .pending(op: current.op))
        }
        guard op > current.appliedOp else {
            // Already recorded; a repeated confirmation is not a new state.
            return Transition(state: current, outcome: .applied(op: op, version: version))
        }
        var next = current
        next.appliedOp = op
        return Transition(state: next, outcome: .applied(op: op, version: version))
    }

    /// What the daemon must publish before it does anything else after a restart.
    public static func reconciliation(_ current: PauseState?) -> PauseState.Desired {
        current?.desired ?? .unpaused
    }

    /// The capability line. A command ack is not a capability: this stays `unavailable` until the signed
    /// activation and applied-acknowledgement rows clear (#990), whatever the command state says.
    public static func capabilityState() -> String { "unavailable" }
}
