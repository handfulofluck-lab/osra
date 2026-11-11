#if canImport(SwiftUI)
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
    @State private var code: String = ""
    @State private var deviceName: String = ""
    @State private var errorMessage: String?
    @State private var pairing = false
    @State private var identity: AgentIdentity?
    /// Called after a successful save so the host app can refresh its root state.
    var onPaired: (AgentIdentity) -> Void = { _ in }

    public init(defaultServer: String = "", onPaired: @escaping (AgentIdentity) -> Void = { _ in }) {
        // Pre-fill with the previously used server (if any) so re-pairing is fast.
        _serverInput = State(initialValue: defaultServer)
        self.onPaired = onPaired
    }

    public var body: some View {
        Form {
            Section(header: Text("OSRA Child Agent")) {
                TextField("Server address (e.g. 192.168.1.5:3000)", text: $serverInput)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                TextField("6-digit pairing code", text: $code)
                    .keyboardType(.numberPad)
                    .onChange(of: code) { newValue in
                        // Hard-limit to 6 digits regardless of keyboard discipline.
                        let digits = newValue.filter(\.isNumber)
                        code = String(digits.prefix(6))
                    }
                TextField("Device name (optional)", text: $deviceName)
                    .textInputAutocapitalization(.words)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section {
                Button(pairing ? "Pairing…" : "Pair this device") {
                    Task { await pair() }
                }
                .disabled(pairing || code.count != 6)
            } footer: {
                // Plan 2.7: after the claim, nothing is paired until the parent taps Allow on their phone.
                Text(pairing
                    ? "Waiting for your parent to tap Allow on their phone…"
                    : "Ask your parent for the pairing code shown in the OSRA parent app.")
            }
        }
        .navigationTitle("Pair device")
    }

    /// Validates input, claims the code, persists the identity and reports success.
    private func pair() async {
        guard let baseURL = PairingClient.normalizeServerURL(serverInput) else {
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
                errorMessage = "Failed to persist identity: shared app group is unavailable. Verify app group provisioning."
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
    #if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
    @StateObject private var screenTime = ScreenTimePermission(authorizer: FamilyControlsAuthorizer())
    #endif

    public init() {}

    public var body: some View {
        NavigationStack {
            if identity != nil, !showRepair, !pinConfigured {
                // ADR-0036: a parent PIN is set right after pairing, and once on a phone paired before this build.
                PinSetupView { pinConfigured = true }
            } else if let identity, !showRepair {
                Form {
                    Section(header: Text("OSRA Child Agent")) {
                        Label("Paired", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        LabeledContent("Child", value: identity.childId)
                        LabeledContent("Server", value: identity.apiBaseURL.absoluteString)
                        if !identity.deviceId.isEmpty {
                            LabeledContent("Device", value: identity.deviceId)
                        }
                    }
                    #if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
                    Section {
                        LabeledContent("Screen Time", value: screenTime.row.value)
                        if screenTime.row.showsButton {
                            Button(ScreenTimeRow.buttonTitle) {
                                Task {
                                    // Approved: fetch and apply the parent's rules now, not at the next open.
                                    if await screenTime.request() { _ = await RuleSyncer.syncNow() }
                                }
                            }
                        }
                        if let error = screenTime.errorMessage {
                            Text(error).foregroundStyle(.red)
                        }
                    } header: {
                        Text("Screen Time")
                    } footer: {
                        Text(screenTime.row.footer)
                    }
                    #endif
                    Section {
                        LabeledContent("Location", value: Self.label(locationGrant))
                        if let title = locationAction.buttonTitle {
                            Button(title) {
                                LocationController.shared.requestPermission()
                                locationAction = LocationController.shared.permissionAction
                            }
                        }
                    } header: {
                        Text("Location")
                    } footer: {
                        Text("Your parents see this device on their map when it moves a noticeable distance, and get alerts for the places they set. Choose \"Allow While Using App\", then \"Change to Always Allow\".")
                    }
                    #if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
                    Section {
                        NavigationLink("App groups") { AppGroupsEntry() }
                    } footer: {
                        Text("Parents only: choose apps to block here. Blocked apps show the OSRA screen with \"Ask parent\".")
                    }
                    #endif
                    Section {
                        // ADR-0036, as on Android: re-pairing needs the parent PIN.
                        Button("Re-pair this device") { askingRepairPin = true }
                    }
                }
                .navigationTitle("Status")
                .sheet(isPresented: $askingRepairPin) {
                    NavigationStack {
                        PinGateView(title: "Re-pair") {
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

    private static func label(_ grant: LocationGrant) -> String {
        switch grant {
        case .background: return "Always"
        case .whileInUse: return "While using the app (needs Always)"
        case .noAccess: return "Off"
        }
    }
}
#if canImport(ManagedSettings) && canImport(FamilyControls) && canImport(DeviceActivity)
/// The PIN first, then the groups (ADR-0036).
struct AppGroupsEntry: View {
    @State private var unlocked = false

    var body: some View {
        if unlocked {
            AppGroupsView()
        } else {
            PinGateView(title: "App groups") { unlocked = true }
        }
    }
}
#endif
#endif
