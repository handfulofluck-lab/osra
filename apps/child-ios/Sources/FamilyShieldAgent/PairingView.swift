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
                Text("Ask your parent for the pairing code shown in the OSRA parent app.")
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

    public init() {}

    public var body: some View {
        NavigationStack {
            if let identity, !showRepair {
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
                    Section {
                        Button("Re-pair this device") { showRepair = true }
                    }
                }
                .navigationTitle("Status")
            } else {
                PairingView(
                    defaultServer: identity?.apiBaseURL.absoluteString ?? "",
                    onPaired: { newIdentity in
                        identity = newIdentity
                        showRepair = false
                        Task { await RuleSyncer.syncNow() }
                        // A new device id: ask iOS for the token again so it is uploaded for this pairing.
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                )
            }
        }
        .onAppear { identity = AgentIdentityStore.load() }
        // On open: drain the command queue, then fetch the rules (5.5 PR C, D). A failed sync keeps the last
        // stored rules in force. A wake push drains the queue the same way (`OSRAAgentAppDelegate`).
        .task {
            await CommandDrainer.drainNow()
            await RuleSyncer.syncNow()
        }
    }
}
#endif
