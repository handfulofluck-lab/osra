#if os(iOS)
import SwiftUI

public struct RingView: View {
    @ObservedObject var controller: RingController
    @State private var pin = ""
    @State private var pinMessage: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    public init(controller: RingController) {
        self.controller = controller
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(color(0xEAF2F0, 0x1E2A31))
                            .frame(width: 88, height: 88)
                        Image(systemName: "bell.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(color(0x0B5D57, 0x7DB4FF))
                            .accessibilityHidden(true)
                    }
                    .padding(.top, 24)
                    // #760 (Arabic Bureau 7152533494): the full sentence is the heading and must wrap — at the
                    // largest text size a cut sentence is the one line that tells the child why the phone rings.
                    // `fixedSize` refuses the single-line compaction that truncated it; the bar carries the short
                    // `ring_nav_title` instead.
                    Text(L10n.tr("ring_title"))
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.tr("ring_explanation"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    PinGateView(title: L10n.tr("ring_pin_title"), pin: $pin, message: $pinMessage, onUnlock: stopRing, showsButtons: false)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 240)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            // #760: a bar name that fits at any text size, with the sentence in the content where it can wrap.
            .navigationTitle(L10n.tr("ring_nav_title"))
            .navigationBarTitleDisplayMode(.inline)
            .background(color(0xF1F5F4, 0x0E1417).ignoresSafeArea())
            .accessibilityIdentifier(A11yID.ringView)
            .interactiveDismissDisabled()
            .safeAreaInset(edge: .bottom) {
                Button(action: checkPin) {
                    Text(L10n.tr("pin_continue"))
                        .font(.body.bold())
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .disabled(pin.count < ParentPin.minLength)
                .foregroundStyle(color(0xFFFFFF, 0x0E1417))
                .background(pin.count < ParentPin.minLength ? color(0xC9D6D3, 0x3A4A53) : continueButtonColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier(A11yID.pinContinue)
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    Task {
                        await controller.enterBackground()
                        await RingNotifier.showReturnNotification()
                    }
                }
            }
        }
    }

    private var continueButtonColor: Color {
        colorScheme == .dark
            ? Color(red: 125 / 255, green: 180 / 255, blue: 255 / 255)
            : Color(red: 11 / 255, green: 93 / 255, blue: 87 / 255)
    }

    private func checkPin() {
        let result = ParentPinStore.check(pin)
        pin = ""
        pinMessage = PinGateMessage.text(for: result)
        if result == .ok { stopRing() }
    }

    private func stopRing() {
        Task {
            await controller.stop(.pinVerified)
            RingNotifier.cancel()
        }
    }

    private func color(_ light: UInt, _ dark: UInt) -> Color {
        let hex = colorScheme == .dark ? dark : light
        return Color(red: Double((hex >> 16) & 0xFF) / 255,
                     green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }
}
#endif
