#if os(iOS)
import SwiftUI

public struct RingView: View {
    @ObservedObject var controller: RingController
    @State private var pinConfigured = ParentPinStore.isConfigured
    var onPinConfigured: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    public init(controller: RingController, onPinConfigured: (() -> Void)? = nil) {
        self.controller = controller
        self.onPinConfigured = onPinConfigured
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
                    Text(L10n.tr("ring_title"))
                        .font(.system(size: 26, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text(L10n.tr("ring_explanation"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Group {
                        if RingPINPresentation.resolve(isConfigured: pinConfigured) == .setup {
                            PinSetupView {
                                pinConfigured = true
                                onPinConfigured?()
                            }
                        } else {
                            PinGateView(title: L10n.tr("ring_pin_title")) {
                                Task {
                                    await controller.stop(.pinVerified)
                                    RingNotifier.cancel()
                                }
                            }
                        }
                    }
                    .frame(minHeight: 240)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(color(0xF1F5F4, 0x0E1417).ignoresSafeArea())
            .accessibilityIdentifier(A11yID.ringView)
            .interactiveDismissDisabled()
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    Task { await RingNotifier.showReturnNotification() }
                }
            }
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
