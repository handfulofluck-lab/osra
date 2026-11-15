import Foundation
import os

/// The daemon's log: subsystem `com.osratech.agent` (#775), read with
/// `log show --predicate 'subsystem == "com.osratech.agent"'`.
///
/// **No personal data and no secrets.** Every line is built in this package from fixed words and numbers: a
/// state, an HTTP status, a rules version, a count. Nothing from the server (names, ids, tokens, rule contents)
/// and nothing typed by a person (the pairing code, the child's account name) is ever passed in, which is why
/// the lines can be public in the unified log. `AgentLoopTests` plants an identity full of marker strings and
/// fails if any reaches a line.
public enum AgentLog {
    private static let logger = Logger(subsystem: "com.osratech.agent", category: "Agent")

    public static func write(_ line: String) {
        logger.notice("\(line, privacy: .public)")
    }
}
