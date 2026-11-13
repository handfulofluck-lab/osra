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
    @State private var serverBlocked = RuleStore.blockedGroupIds()

    public init() {}

    public var body: some View {
        Form {
            if list.groups.isEmpty {
                Section { Text(L10n.tr("groups_empty")).foregroundStyle(.secondary) }
            }
            ForEach(list.groups, id: \.id) { group in
                let byParentApp = list.isBlockedByParentApp(id: group.id, serverBlocked: serverBlocked)
                Section {
                    // ADR-0037 PR B3: a group blocked from the parent app stays blocked here; only the parent app
                    // can lift that block.
                    Toggle(L10n.tr("groups_blocked"), isOn: Binding(
                        get: { group.blocked || byParentApp },
                        set: { list.setBlocked($0, id: group.id); commit() }
                    ))
                    .disabled(byParentApp)
                    .accessibilityIdentifier(A11yID.group(group.id, .blocked))
                    LabeledContent(L10n.tr("groups_chosen"), value: group.counts.summary)
                        .accessibilityIdentifier(A11yID.group(group.id, .chosen))
                    Button(L10n.tr("groups_change")) {
                        editingId = group.id
                        editSelection = group.selection
                        pickingEdit = true
                    }
                    .accessibilityIdentifier(A11yID.group(group.id, .change))
                    Button(L10n.tr("groups_delete"), role: .destructive) {
                        list.remove(id: group.id)
                        commit()
                    }
                    .accessibilityIdentifier(A11yID.group(group.id, .delete))
                } header: {
                    Text(group.label)
                } footer: {
                    if group.counts.isEmpty {
                        Text(L10n.tr("groups_empty_footer"))
                    } else if byParentApp {
                        Text(L10n.tr("groups_by_parent"))
                    }
                }
            }
            Section {
                TextField(L10n.tr("groups_name_field"), text: $newLabel)
                    .accessibilityIdentifier(A11yID.groupsNewName)
                Button(L10n.tr("groups_choose")) { pickingNew = true }
                    .accessibilityIdentifier(A11yID.groupsNewChoose)
                LabeledContent(L10n.tr("groups_chosen"), value: newSelection.counts.summary)
                    .accessibilityIdentifier(A11yID.groupsNewChosen)
                Button(L10n.tr("groups_add")) { addGroup() }
                    .accessibilityIdentifier(A11yID.groupsNewAdd)
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier(A11yID.groupsError) }
            } header: {
                Text(L10n.tr("groups_new"))
            } footer: {
                Text(L10n.tr("groups_new_footer"))
            }
        }
        .navigationTitle(L10n.tr("groups"))
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
            error = L10n.tr("groups_error_choose")
            return
        }
        guard list.add(label: newLabel, selection: newSelection, blocked: true) != nil else {
            error = AppGroupLabel.sanitize(newLabel) == nil
                ? L10n.tr("groups_error_name")
                : L10n.tr("groups_error_max")
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
        // ADR-0037: the parent sees the change (label and counts only) without waiting for the next open.
        Task { await LocationController.shared.reportGrant() }
    }
}
#endif
