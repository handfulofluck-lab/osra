import Foundation

/// A daily recurring time window (for example a bedtime window), with support for
/// windows that wrap around local midnight and for unbounded windows whose end is
/// the end of the day (`endMinutes == 1440`).
public struct RoutineWindow: Equatable {

    /// Minutes after local midnight at which the window opens (inclusive).
    public let startMinutes: Int

    /// Minutes after local midnight at which the window closes (exclusive).
    /// A value of 1440 means unbounded: every time at or after `startMinutes` is inside.
    public let endMinutes: Int

    /// Creates a window from hour/minute pairs; values are clamped to a single day (0...1440).
    public init(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
        self.init(
            startMinutes: min(1440, max(0, startHour * 60 + startMinute)),
            endMinutes: min(1440, max(0, endHour * 60 + endMinute))
        )
    }

    /// Creates a window from minutes-after-midnight values, clamped to 0...1440.
    public init(startMinutes: Int, endMinutes: Int) {
        self.startMinutes = min(1440, max(0, startMinutes))
        self.endMinutes = min(1440, max(0, endMinutes))
    }

    /// True when the window crosses local midnight (start at or after end).
    /// An unbounded window (`endMinutes == 1440`) never wraps.
    public var wrapsMidnight: Bool { endMinutes < 1440 && startMinutes >= endMinutes }

    /// Returns true if `date` falls inside the window, evaluated in the given calendar.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return Self.isWithinWindow(minutesOfDay: minutes, startMinutes: startMinutes, endMinutes: endMinutes)
    }

    /// Returns true if the time `minutesOfDay` minutes after local midnight falls inside the window.
    public func contains(minutesOfDay: Int) -> Bool {
        Self.isWithinWindow(minutesOfDay: minutesOfDay, startMinutes: startMinutes, endMinutes: endMinutes)
    }

    /// Pure window test: true when `minutesOfDay` lies in `[start, end)`.
    ///
    /// When `startMinutes == endMinutes` the window is treated as covering the whole day.
    /// When `endMinutes == 1440` the window is unbounded: every `t >= startMinutes` is inside.
    public static func isWithinWindow(minutesOfDay: Int, startMinutes: Int, endMinutes: Int) -> Bool {
        let t = ((minutesOfDay % 1440) + 1440) % 1440
        let start = min(1440, max(0, startMinutes))
        let end = min(1440, max(0, endMinutes))
        if start == end { return true } // whole day (existing wrap-around semantics)
        if end >= 1440 { return t >= start } // unbounded: from start to end of day
        if start >= end { return t >= start || t < end } // wraps around local midnight
        return t >= start && t < end
    }
}
