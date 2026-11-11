import Foundation

/// App groups (ADR-0036, #372 PR A). On iOS the OSRA shield appears only for apps chosen in Apple's
/// `FamilyActivityPicker`, which hands back opaque tokens: the app can neither name them nor send them anywhere.
/// So the parent makes groups on the child phone, behind the parent PIN. Each group has a phone-made UUID, a
/// label the parent types, and the picker's selection, and is kept in the app group for the extensions.
///
/// This PR keeps the groups on the phone: blocking happens on the phone and nothing is reported. PR B adds them
/// to the server's strict capability schema first, then the phone field, so an early report cannot be refused.
///
/// The model is generic over the selection, so the tests use a plain Codable stand-in and never touch
/// FamilyControls; the app uses `FamilyActivitySelection`.

/// What a selection holds, as counts only: the most the server will ever learn about a group (PR B).
public struct AppGroupCounts: Codable, Equatable {
    public var apps: Int
    public var categories: Int
    public var sites: Int

    public init(apps: Int, categories: Int, sites: Int) {
        self.apps = apps
        self.categories = categories
        self.sites = sites
    }

    public var isEmpty: Bool { apps == 0 && categories == 0 && sites == 0 }

    /// "5 apps, 1 category" for the groups screen; "Nothing chosen" when the tokens are gone (a Screen Time reset).
    public var summary: String {
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) app\(apps == 1 ? "" : "s")") }
        if categories > 0 { parts.append("\(categories) categor\(categories == 1 ? "y" : "ies")") }
        if sites > 0 { parts.append("\(sites) website\(sites == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing chosen" : parts.joined(separator: ", ")
    }
}

public protocol AppGroupSelection: Codable {
    var counts: AppGroupCounts { get }
}

/// The label is typed on the child phone, so it is cleaned here and again on the server (PR B), which never logs it.
public enum AppGroupLabel {
    public static let maxLength = 40

    /// Trims, drops control characters, folds runs of whitespace to one space and caps the length; nil if nothing
    /// is left.
    public static func sanitize(_ raw: String) -> String? {
        let visible = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let folded = String(String.UnicodeScalarView(visible))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let capped = String(folded.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }
}

public struct AppGroupRecord<Selection: AppGroupSelection>: Codable {
    public let id: String
    public var label: String
    public var blocked: Bool
    public var selection: Selection

    public var counts: AppGroupCounts { selection.counts }
}

/// The groups and the edits the screen makes, kept pure.
public struct AppGroupList<Selection: AppGroupSelection>: Codable {
    public private(set) var groups: [AppGroupRecord<Selection>] = []

    public static var maxGroups: Int { 20 }

    public init(groups: [AppGroupRecord<Selection>] = []) {
        self.groups = groups
    }

    /// Adds a group with a fresh random id; nil when the label is empty after cleaning or the list is full.
    @discardableResult
    public mutating func add(label: String, selection: Selection, blocked: Bool = false,
                             id: UUID = UUID()) -> String? {
        guard let clean = AppGroupLabel.sanitize(label), groups.count < Self.maxGroups else { return nil }
        let record = AppGroupRecord(id: id.uuidString, label: clean, blocked: blocked, selection: selection)
        groups.append(record)
        return record.id
    }

    public mutating func setBlocked(_ blocked: Bool, id: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].blocked = blocked
    }

    public mutating func setSelection(_ selection: Selection, id: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].selection = selection
    }

    @discardableResult
    public mutating func rename(_ label: String, id: String) -> Bool {
        guard let i = groups.firstIndex(where: { $0.id == id }), let clean = AppGroupLabel.sanitize(label) else { return false }
        groups[i].label = clean
        return true
    }

    public mutating func remove(id: String) {
        groups.removeAll { $0.id == id }
    }

    /// The selections the shield must cover: those of the blocked groups only, never every picked token
    /// (the old `TokenResolver` returned every picked token for any rule).
    public var blockedSelections: [Selection] {
        groups.filter(\.blocked).map(\.selection)
    }
}

/// The groups in the app group's defaults, where the shield extensions can read them.
public struct AppGroupStore<Selection: AppGroupSelection> {
    public static var key: String { "appGroups.v1" }

    let defaults: UserDefaults?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: AgentIdentityStore.suiteName)) {
        self.defaults = defaults
    }

    public func load() -> AppGroupList<Selection> {
        guard let data = defaults?.data(forKey: Self.key),
              let list = try? PropertyListDecoder().decode(AppGroupList<Selection>.self, from: data) else {
            return AppGroupList()
        }
        return list
    }

    @discardableResult
    public func save(_ list: AppGroupList<Selection>) -> Bool {
        guard let defaults, let data = try? PropertyListEncoder().encode(list) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }

    public func clear() {
        defaults?.removeObject(forKey: Self.key)
    }
}
