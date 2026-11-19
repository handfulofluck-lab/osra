import Foundation

#if os(iOS)
import AVFoundation
#endif

public protocol RingAudioPlaying: Sendable {
    func start() async
    func stop() async
}

#if os(iOS)
@MainActor
public final class RingAudioPlayer: RingAudioPlaying {
    private var player: AVAudioPlayer?

    public init() {}

    public func start() async {
        guard player?.isPlaying != true else { return }
        guard let url = Bundle.main.url(forResource: "ring", withExtension: "wav") else {
            RingAlarmLog.info("ring sound not found in bundle")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.prepareToPlay()
            player.play()
            self.player = player
            RingAlarmLog.info("ring audio started")
        } catch {
            RingAlarmLog.error("ring audio", error)
        }
    }

    public func stop() async {
        player?.stop()
        player = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            RingAlarmLog.error("ring audio session", error)
        }
    }
}
#else
@MainActor
public final class RingAudioPlayer: RingAudioPlaying {
    public init() {}
    public func start() async {}
    public func stop() async {}
}
#endif
