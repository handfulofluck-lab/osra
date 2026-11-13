#if canImport(SwiftUI)
import OSLog
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Pairing form (spec §14.2 iOS flow): server URL + 6-digit parent-issued code,
/// mirroring the Android agent's `PairingActivity`. On success the identity is
/// persisted to the shared app group so the Screen Time extensions and
/// `AlertReporter` can use it.
public struct PairingView: View {
    @State private var serverInput: String
    /// #634 G1: the store build's own server, if any; the field is then locked to it.
    private let builtInServer: URL?
    @State private var code: String = ""
    @State private var deviceName: String = ""
    @State private var errorMessage: String?
    @State private var pairing = false
    @State private var identity: AgentIdentity?
    /// Called after a successful save so the host app can refresh its root state.
    var onPaired: (AgentIdentity) -> Void = { _ in }

    public init(defaultServer: String = "", builtInServer: URL? = PairingServerField.builtIn(),
                onPaired: @escaping (AgentIdentity) -> Void = { _ in }) {
        // Pre-fill with the previously used server (if any) so re-pairing is fast; a store build shows its own.
        self.builtInServer = builtInServer
        _serverInput = State(initialValue: PairingServerField.field(builtIn: builtInServer, previous: defaultServer).value)
        self.onPaired = onPaired
    }

    public var body: some View {
        Form {
            Section(header: Text(L10n.tr("pair_section_title"))) {
                TextField(L10n.tr("pair_server_field"), text: $serverInput)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .disabled(builtInServer != nil)
                    .accessibilityIdentifier(A11yID.pairServer)
                TextField(L10n.tr("pair_code_field"), text: $code)
                    .keyboardType(.numberPad)
                    .onChange(of: code) { newValue in
                        // Hard-limit to 6 digits regardless of keyboard discipline.
                        let digits = newValue.filter(\.isNumber)
                        code = String(digits.prefix(6))
                    }
                    .accessibilityIdentifier(A11yID.pairCode)
                TextField(L10n.tr("pair_name_field"), text: $deviceName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier(A11yID.pairName)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .accessibilityIdentifier(A11yID.pairError)
                }
            }

            Section {
                Button(pairing ? L10n.tr("pair_button_busy") : L10n.tr("pair_button")) {
                    Task { await pair() }
                }
                .disabled(pairing || code.count != 6)
                .accessibilityIdentifier(A11yID.pairButton)
            } footer: {
                // Plan 2.7: after the claim, nothing is paired until the parent taps Allow on their phone.
                Text(pairing
                    ? L10n.tr("pair_waiting")
                    : L10n.tr("pair_hint"))
            }
        }
        .navigationTitle(L10n.tr("pair_title"))
    }

    /// Validates input, claims the code, persists the identity and reports success.
    private func pair() async {
        guard let baseURL = PairingServerField.serverToPair(builtIn: builtInServer, typed: serverInput) else {
            errorMessage = PairingClient.message(for: PairingError.invalidServerURL)
            return
        }
        guard code.count == 6 else {
            errorMessage = PairingClient.message(for: PairingError.invalidCode)
            return
        }
        pairing = true
        errorMessage = nil
        defer { pairing = false }
        do {
            let client = PairingClient()
            let claimed = try await client.claim(baseURL: baseURL, code: code, deviceName: deviceName)
            guard AgentIdentityStore.save(claimed) else {
                // The family reads a plain sentence; the technical cause goes to the log (Bureau review, 12 Nov).
                Logger(subsystem: "com.osratech.child", category: "pairing")
                    .error("Failed to persist identity: shared app group is unavailable. Verify app group provisioning.")
                errorMessage = L10n.tr("pair_error_save")
                return
            }
            identity = claimed
            onPaired(claimed)
        } catch {
            errorMessage = PairingClient.message(for: error)
        }
    }
}

/// Root switch for the host app: status + re-pair when already paired,
/// the pairing form otherwise.
public struct AgentRootView: View {
    @State private var identity: AgentIdentity?
    @State private var showRepair = false
    @State private var pinConfigured = ParentPinStore.isConfigured
    @State private var askingRepairPin = false
    @State private var locationGrant: LocationGrant = .noAccess
    @State private var locationAction: LocationPermissionAction = .hidden
    /// #602: when the rules were last synced, and the Sync now button's state.
    @State private var syncedAt: Date? = RuleStore.syncedAt()
    @State private var syncing = false
    @State private var syncFailed = false
    #if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
    @StateObject private var screenTime = ScreenTimePermission(authorizer: FamilyControlsAuthorizer())
    #endif

    public init() {}

    public var body: some View {
        NavigationStack {
            if identity != nil, !showRepair, !pinConfigured {
                // ADR-0037: a parent PIN is set right after pairing, and once on a phone paired before this build.
                PinSetupView { pinConfigured = true }
            } else if let identity, !showRepair {
                Form {
                    Section(header: Text(L10n.tr("pair_section_title"))) {
                        Label(L10n.tr("status_paired"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier(A11yID.statusPaired)
                        // #602: the child's name, never a raw id; the device id is not shown at all.
                        if let name = identity.childName {
                            LabeledContent(L10n.tr("status_child_name"), value: name)
                                .accessibilityIdentifier(A11yID.statusChildName)
                        }
                        LabeledContent(L10n.tr("status_server"), value: identity.apiBaseURL.absoluteString)
                            .accessibilityIdentifier(A11yID.statusServer)
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            let state = SyncStatus.state(syncedAt: syncedAt, now: context.date)
                            Text(SyncStatus.text(state, now: context.date))
                                .foregroundStyle(stale(state) ? Color.orange : Color.secondary)
                                .accessibilityIdentifier(A11yID.statusLastSynced)
                        }
                    }
                    Section {
                        Button(syncing ? L10n.tr("status_syncing") : L10n.tr("status_sync_now")) {
                            Task { await syncNow() }
                        }
                        .disabled(syncing)
                        .accessibilityIdentifier(A11yID.statusSyncNow)
                        if syncFailed {
                            Text(L10n.tr("status_sync_failed")).foregroundStyle(.red)
                                .accessibilityIdentifier(A11yID.statusSyncFailed)
                        }
                    } footer: {
                        Text(L10n.tr("status_sync_note"))
                    }
                    #if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
                    Section {
                        LabeledContent(L10n.tr("screen_time"), value: screenTime.row.value)
                            .accessibilityIdentifier(A11yID.statusScreenTime)
                        if screenTime.row.showsButton {
                            Button(ScreenTimeRow.buttonTitle) {
                                Task {
                                    // Approved: fetch and apply the parent's rules now, not at the next open.
                                    if await screenTime.request() { _ = await RuleSyncer.syncNow() }
                                    await LocationController.shared.reportGrant()
                                }
                            }
                            .accessibilityIdentifier(A11yID.statusScreenTimeButton)
                        }
                        if let error = screenTime.errorMessage {
                            Text(error).foregroundStyle(.red)
                        }
                    } header: {
                        Text(L10n.tr("screen_time"))
                    } footer: {
                        Text(screenTime.row.footer)
                    }
                    #endif
                    Section {
                        LabeledContent(L10n.tr("location"), value: Self.label(locationGrant))
                            .accessibilityIdentifier(A11yID.statusLocation)
                        if let title = locationAction.buttonTitle {
                            Button(title) {
                                LocationController.shared.requestPermission()
                                locationAction = LocationController.shared.permissionAction
                            }
                            .accessibilityIdentifier(A11yID.statusLocationButton)
                        }
                    } header: {
                        Text(L10n.tr("location"))
                    } footer: {
                        Text(L10n.tr("location_footer"))
                    }
                    #if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
                    Section {
                        NavigationLink(L10n.tr("groups")) { AppGroupsEntry() }
                            .accessibilityIdentifier(A11yID.statusGroups)
                    } footer: {
                        Text(L10n.tr("groups_status_footer"))
                    }
                    #endif
                    Section {
                        // ADR-0037, as on Android: re-pairing needs the parent PIN.
                        Button(L10n.tr("repair_button")) { askingRepairPin = true }
                            .accessibilityIdentifier(A11yID.statusRepair)
                    }
                }
                .navigationTitle(L10n.tr("status_title"))
                .sheet(isPresented: $askingRepairPin) {
                    NavigationStack {
                        PinGateView(title: L10n.tr("repair_title")) {
                            askingRepairPin = false
                            showRepair = true
                        }
                    }
                }
            } else {
                PairingView(
                    defaultServer: identity?.apiBaseURL.absoluteString ?? "",
                    onPaired: { newIdentity in
                        identity = newIdentity
                        showRepair = false
                        pinConfigured = ParentPinStore.isConfigured
                        Task {
                            let synced = await RuleSyncer.syncNow()
                            await LocationController.shared.apply(synced)
                            await LocationController.shared.reportGrant()
                        }
                        // A new device id: ask iOS for the token again so it is uploaded for this pairing.
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                )
            }
        }
        .onAppear {
            identity = AgentIdentityStore.load()
            pinConfigured = ParentPinStore.isConfigured
            locationGrant = LocationController.shared.grant
            locationAction = LocationController.shared.permissionAction
            #if canImport(UIKit)
            LocationController.shared.openSettings = {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            #endif
        }
        // On open: drain the command queue, then fetch the rules (5.5 PR C, D). A failed sync keeps the last
        // stored rules in force. A wake push drains the queue the same way (`OSRAAgentAppDelegate`).
        .task {
            let drained = await CommandDrainer.drainNow()
            if drained.consentWithdrawn { await LocationController.shared.stopForConsent() }
            let synced = await RuleSyncer.syncNow()
            await LocationController.shared.apply(synced)
            await LocationController.shared.flush()
            // ADR-0034 A6: each app open also sends the capability report.
            await LocationController.shared.reportGrant()
            syncedAt = RuleStore.syncedAt()
            leaveIfUnpaired()
        }
        // The grant changes in Settings or at the prompt; the controller reports it, the screen shows it.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            locationGrant = LocationController.shared.grant
            locationAction = LocationController.shared.permissionAction
            #if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
            screenTime.refresh()
            #endif
        }
    }

    /// #602 item 4: what an app open does, on demand (a push wake can take minutes in the background).
    private func syncNow() async {
        syncing = true
        syncFailed = false
        defer { syncing = false }
        let drained = await CommandDrainer.drainNow()
        if drained.consentWithdrawn { await LocationController.shared.stopForConsent() }
        let synced = await RuleSyncer.syncNow()
        await LocationController.shared.apply(synced)
        await LocationController.shared.reportGrant()
        syncFailed = !SyncStatus.succeeded(synced)
        syncedAt = RuleStore.syncedAt()
        leaveIfUnpaired()
    }

    /// #690: the parent removed this phone during a drain or sync, so the pairing is gone; show pairing.
    private func leaveIfUnpaired() {
        guard identity != nil, AgentIdentityStore.load() == nil else { return }
        identity = nil
        syncFailed = false
        pinConfigured = ParentPinStore.isConfigured
    }

    private func stale(_ state: SyncStatus.State) -> Bool {
        if case .stale = state { return true }
        return false
    }

    private static func label(_ grant: LocationGrant) -> String {
        switch grant {
        case .background: return L10n.tr("location_always")
        case .whileInUse: return L10n.tr("location_while_in_use")
        case .noAccess: return L10n.tr("location_off")
        }
    }
}
#if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
/// The PIN first, then the groups (ADR-0037).
struct AppGroupsEntry: View {
    @State private var unlocked = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if unlocked {
                AppGroupsView()
            } else {
                PinGateView(title: L10n.tr("groups")) { unlocked = true }
            }
        }
        // Relocks when the app leaves the screen, so a parent cannot leave the groups open by accident.
        .onChange(of: scenePhase) { phase in
            if phase == .background { unlocked = false }
        }
    }
}
#endif
#endif
