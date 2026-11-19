#if os(iOS)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Set at pairing on the phone, as on Android (ADR-0037): the parent holds the phone then, and no PIN or hash
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
            // U11 (#696): the screen cannot be skipped, so it says why first.
            Section {
                Text(L10n.tr("pin_set_reason"))
                    .accessibilityIdentifier(A11yID.pinSetReason)
            }
            Section {
                SecureField(L10n.tr("pin_new_field"), text: $pin).keyboardType(.numberPad)
                    .accessibilityIdentifier(A11yID.pinNew)
                SecureField(L10n.tr("pin_repeat_field"), text: $confirm).keyboardType(.numberPad)
                    .accessibilityIdentifier(A11yID.pinRepeat)
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier(A11yID.pinSetError) }
                Button(L10n.tr("pin_save")) { save() }
                    .accessibilityIdentifier(A11yID.pinSave)
            } header: {
                Text(L10n.tr("pin_parent"))
            } footer: {
                Text(L10n.tr("pin_set_footer"))
            }
        }
        .navigationTitle(L10n.tr("pin_set_title"))
    }

    private func save() {
        if let reason = ParentPin.validationError(pin) {
            error = reason
        } else if pin != confirm {
            error = L10n.tr("pin_mismatch")
        } else if !ParentPinStore.set(pin) {
            error = L10n.tr("pin_save_failed")
        } else {
            error = nil
            onDone()
        }
        confirm = ""
    }
}

/// Asks for the parent PIN; after five wrong PINs it locks with a growing delay and wipes nothing.
public struct PinGateView: View {
    @State private var internalPin = ""
    @State private var internalMessage: String?
    @Binding private var externalPin: String
    @Binding private var externalMessage: String?
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var onUnlock: () -> Void
    var showsButtons: Bool
    private let usesExternalState: Bool

    public init(title: String, onUnlock: @escaping () -> Void) {
        self.title = title
        self.onUnlock = onUnlock
        self._externalPin = .constant("")
        self._externalMessage = .constant(nil)
        self.showsButtons = true
        self.usesExternalState = false
    }

    public init(title: String, pin: Binding<String>, message: Binding<String?>, onUnlock: @escaping () -> Void, showsButtons: Bool = false) {
        self.title = title
        self.onUnlock = onUnlock
        self._externalPin = pin
        self._externalMessage = message
        self.showsButtons = showsButtons
        self.usesExternalState = true
    }

    private var pin: Binding<String> { usesExternalState ? $externalPin : $internalPin }
    private var message: Binding<String?> { usesExternalState ? $externalMessage : $internalMessage }

    private var continueButtonColor: Color {
        // UI/UX Bureau (#760): brand teal in light, matching light blue in dark.
        colorScheme == .dark
            ? Color(red: 125 / 255, green: 180 / 255, blue: 255 / 255)
            : Color(red: 11 / 255, green: 93 / 255, blue: 87 / 255)
    }

    public var body: some View {
        Form {
            Section {
                SecureField(L10n.tr("pin_parent"), text: pin).keyboardType(.numberPad)
                    .accessibilityIdentifier(A11yID.pinGate)
                if let message = message.wrappedValue { Text(message).foregroundStyle(.red).accessibilityIdentifier(A11yID.pinGateMessage) }
                if showsButtons {
                    Button(L10n.tr("pin_continue")) { check() }
                        .accessibilityIdentifier(A11yID.pinContinue)
                }
            } footer: {
                Text(L10n.tr("pin_parents_only"))
            }
        }
        .navigationTitle(title)
        .toolbar {
            if showsButtons {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.tr("pin_continue")) { check() }
                        .foregroundStyle(continueButtonColor)
                        .accessibilityIdentifier(A11yID.pinContinue)
                }
            }
        }
    }

    private func check() {
        let result = ParentPinStore.check(pin.wrappedValue)
        pin.wrappedValue = ""
        message.wrappedValue = PinGateMessage.text(for: result)
        if result == .ok { onUnlock() }
    }

}
#endif
