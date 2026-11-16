import Foundation
@testable import FamilyShieldAgent

final class FakeRingAudioPlayer: RingAudioPlaying {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    func start() async {
        startCalls += 1
    }

    func stop() async {
        stopCalls += 1
    }
}
