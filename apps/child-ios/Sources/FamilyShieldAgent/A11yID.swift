import Foundation

/// #669: stable accessibility identifiers for the OSRA Kids screens. The test bed's XCUITest driver taps by these
/// instead of by label, so one script runs in English and in Arabic. Nobody reads them and they are never
/// translated. The block screen is drawn by iOS from `ShieldConfiguration` and takes no identifiers.
public enum A11yID {
    // Pairing
    public static let pairServer = "pair.server"
    public static let pairCode = "pair.code"
    public static let pairName = "pair.name"
    public static let pairError = "pair.error"
    public static let pairButton = "pair.button"

    // Status
    public static let statusPaired = "status.paired"
    public static let statusChildName = "status.childName"
    public static let statusServer = "status.server"
    public static let statusLastSynced = "status.lastSynced"
    public static let statusSyncNow = "status.syncNow"
    public static let statusSyncFailed = "status.syncFailed"
    public static let statusScreenTime = "status.screenTime"
    public static let statusScreenTimeButton = "status.screenTime.button"
    public static let statusLocation = "status.location"
    public static let statusLocationButton = "status.location.button"
    public static let statusGroups = "status.groups"
    public static let statusRepair = "status.repair"

    // Parent PIN (set after pairing, and the gate that asks the parent)
    public static let pinNew = "pin.new"
    public static let pinRepeat = "pin.repeat"
    public static let pinSetError = "pin.setError"
    public static let pinSave = "pin.save"
    public static let pinGate = "pin.gate"
    public static let pinGateMessage = "pin.gateMessage"
    public static let pinContinue = "pin.continue"

    // App groups
    public static let groupsNewName = "groups.new.name"
    public static let groupsNewChoose = "groups.new.choose"
    public static let groupsNewChosen = "groups.new.chosen"
    public static let groupsNewAdd = "groups.new.add"
    public static let groupsError = "groups.error"

    /// A control in one group's section, keyed by the group's id so a script can find a group it created.
    public static func group(_ id: String, _ part: GroupPart) -> String { "groups.\(id).\(part.rawValue)" }

    public enum GroupPart: String, CaseIterable {
        case blocked, chosen, change, delete
    }

    /// Every fixed identifier, for the uniqueness test.
    public static let all: [String] = [
        pairServer, pairCode, pairName, pairError, pairButton,
        statusPaired, statusChildName, statusServer, statusLastSynced, statusSyncNow, statusSyncFailed,
        statusScreenTime, statusScreenTimeButton, statusLocation, statusLocationButton, statusGroups, statusRepair,
        pinNew, pinRepeat, pinSetError, pinSave, pinGate, pinGateMessage, pinContinue,
        groupsNewName, groupsNewChoose, groupsNewChosen, groupsNewAdd, groupsError,
    ]
}
