#if os(iOS)
import SwiftUI

public struct RingView: View {
    @ObservedObject var controller: RingController
    @Environment(\.scenePhase) private var scenePhase

    public init(controller: RingController) {
        self.controller = controller
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "bell.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(L10n.tr("ring_title"))
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(L10n.tr("ring_explanation"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
                PinGateView(title: L10n.tr("ring_pin_title")) {
                    Task {
                        await controller.stop(.pinVerified)
                        RingNotifier.cancel()
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground).ignoresSafeArea())
            .accessibilityIdentifier(A11yID.ringView)
            .interactiveDismissDisabled()
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    Task { await RingNotifier.showReturnNotification() }
                }
            }
        }
    }
}
#endif
