import Darwin
import Foundation

/// ADR-0036 rule 4 and ADR-0041 D5.5: the model is "the parent is the administrator, the child is a Standard
/// user". A Standard user cannot unload a root daemon; an administrator can. So pairing checks the child's
/// macOS account and says when protection is weak.
///
/// This step only detects it and reports it on the command line and in the log. The warning the parent reads
/// in the parent app needs the `child_account_admin` capability, which ADR-0041 adds to the server's
/// vocabulary as its own change, with the Bureaus' wording.
public enum ChildAccount {
    /// macOS's `admin` group.
    public static let adminGroupID: gid_t = 80

    public enum Kind: String, Equatable {
        case standard
        case administrator
        /// No such account on this Mac.
        case unknown
    }

    /// The decision, pure: an account in group 80, or root itself, administers the Mac.
    public static func kind(userID: uid_t?, groupIDs: [gid_t]?) -> Kind {
        guard let userID, let groupIDs else { return .unknown }
        return (userID == 0 || groupIDs.contains(adminGroupID)) ? .administrator : .standard
    }

    public static func kind(ofUser name: String) -> Kind {
        guard let entry = getpwnam(name) else { return .unknown }
        return kind(userID: entry.pointee.pw_uid, groupIDs: groupIDs(ofUser: name, primary: entry.pointee.pw_gid))
    }

    /// Every group the account is in, the primary one included; nil when the system cannot say.
    static func groupIDs(ofUser name: String, primary: gid_t) -> [gid_t]? {
        var count: Int32 = 64
        var groups = [Int32](repeating: 0, count: Int(count))
        if getgrouplist(name, Int32(bitPattern: primary), &groups, &count) == -1 {
            // Too small: `count` now holds the number needed.
            guard count > 0 else { return nil }
            groups = [Int32](repeating: 0, count: Int(count))
            guard getgrouplist(name, Int32(bitPattern: primary), &groups, &count) != -1 else { return nil }
        }
        return groups.prefix(Int(count)).map { gid_t(bitPattern: $0) }
    }
}
