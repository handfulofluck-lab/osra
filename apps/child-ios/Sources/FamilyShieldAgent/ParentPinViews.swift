#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Set at pairing on the phone, as on Android (ADR-0036): the parent holds the phone then, and no PIN or hash
/// ever reaches the server. A phone paired before this build is asked once, on its next open.
public struct PinSetupView: View {
    @State private var pin = ""
    @State private var confirm = ""
    @State private var error: String?
    var onDone: () -> Void

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        Form {
            Section {
                SecureField("New PIN (4-8 digits)", text: $pin).keyboardType(.numberPad)
                SecureField("Repeat the PIN", text: $confirm).keyboardType(.numberPad)
                if let error { Text(error).foregroundStyle(.red) }
                Button("Save PIN") { save() }
            } header: {
                Text("Parent PIN")
            } footer: {
                Text("Parents only. The PIN protects the app groups and re-pairing on this phone. It stays on this phone and is never sent anywhere.")
            }
        }
        .navigationTitle("Set a parent PIN")
    }

    private func save() {
        if let reason = ParentPin.validationError(pin) {
            error = reason
        } else if pin != confirm {
            error = "The two PINs are different."
        } else if !ParentPinStore.set(pin) {
            error = "The PIN could not be saved. Try again."
        } else {
            error = nil
            onDone()
        }
        confirm = ""
    }
}

/// Asks for the parent PIN; after five wrong PINs it locks with a growing delay and wipes nothing.
public struct PinGateView: View {
    @State private var pin = ""
    @State private var message: String?
    let title: String
    var onUnlock: () -> Void

    public init(title: String, onUnlock: @escaping () -> Void) {
        self.title = title
        self.onUnlock = onUnlock
    }

    public var body: some View {
        Form {
            Section {
                SecureField("Parent PIN", text: $pin).keyboardType(.numberPad)
                if let message { Text(message).foregroundStyle(.red) }
                Button("Continue") { check() }
            } footer: {
                Text("Parents only.")
            }
        }
        .navigationTitle(title)
    }

    private func check() {
        let result = ParentPinStore.check(pin)
        pin = ""
        message = PinGateMessage.text(for: result)
        if result == .ok { onUnlock() }
    }

}
#endif
