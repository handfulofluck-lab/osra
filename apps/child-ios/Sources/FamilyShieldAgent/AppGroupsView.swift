#if canImport(SwiftUI) && canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
import FamilyControls
import SwiftUI

/// The "App groups" screen (ADR-0037), shown only after the parent PIN. The parent names a group, chooses its apps,
/// categories and websites in Apple's picker, and blocks it here. Blocked groups get the OSRA shield with Ask
/// parent. Nothing about a group leaves the phone in this version.
public struct AppGroupsView: View {
    @State private var list = AppGroupStore<FamilyActivitySelection>().load()
    @State private var newLabel = ""
    @State private var newSelection = FamilyActivitySelection()
    @State private var pickingNew = false
    @State private var editingId: String?
    @State private var editSelection = FamilyActivitySelection()
    @State private var pickingEdit = false
    @State private var error: String?

    public init() {}

    public var body: some View {
        Form {
            if list.groups.isEmpty {
                Section { Text("No groups yet.").foregroundStyle(.secondary) }
            }
            ForEach(list.groups, id: \.id) { group in
                Section {
                    Toggle("Blocked", isOn: Binding(
                        get: { group.blocked },
                        set: { list.setBlocked($0, id: group.id); commit() }
                    ))
                    LabeledContent("Chosen", value: group.counts.summary)
                    Button("Change apps") {
                        editingId = group.id
                        editSelection = group.selection
                        pickingEdit = true
                    }
                    Button("Delete group", role: .destructive) {
                        list.remove(id: group.id)
                        commit()
                    }
                } header: {
                    Text(group.label)
                } footer: {
                    if group.counts.isEmpty {
                        Text("Nothing is chosen, so this group blocks nothing. Tap \"Change apps\" to choose again.")
                    }
                }
            }
            Section {
                TextField("Group name, e.g. Games", text: $newLabel)
                Button("Choose apps") { pickingNew = true }
                LabeledContent("Chosen", value: newSelection.counts.summary)
                Button("Add group") { addGroup() }
                if let error { Text(error).foregroundStyle(.red) }
            } header: {
                Text("New group")
            } footer: {
                Text("Up to \(AppGroupLabel.maxLength) characters. Blocked apps show the OSRA screen with \"Ask parent\".")
            }
        }
        .navigationTitle("App groups")
        .familyActivityPicker(isPresented: $pickingNew, selection: $newSelection)
        .familyActivityPicker(isPresented: $pickingEdit, selection: $editSelection)
        .onChange(of: pickingEdit) { stillPicking in
            guard !stillPicking, let id = editingId else { return }
            list.setSelection(editSelection, id: id)
            editingId = nil
            commit()
        }
    }

    private func addGroup() {
        guard !newSelection.counts.isEmpty else {
            error = "Choose at least one app, category or website."
            return
        }
        guard list.add(label: newLabel, selection: newSelection, blocked: true) != nil else {
            error = AppGroupLabel.sanitize(newLabel) == nil
                ? "Give the group a name."
                : "There can be at most \(AppGroupList<FamilyActivitySelection>.maxGroups) groups."
            return
        }
        error = nil
        newLabel = ""
        newSelection = FamilyActivitySelection()
        commit()
    }

    /// Saves for the extensions, then puts the shields in force at once.
    private func commit() {
        AppGroupStore<FamilyActivitySelection>().save(list)
        ScreenTimeController().applyGroups(list)
    }
}
#endif
