import AVFoundation
import UIKit

/// Тихий аудиопоток, чтобы процесс не засыпал в фоне во время PiP + камеры.
final class PiPAudioKeepAlive: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP]
        )
        try? session.setActive(true)

        let node = AVAudioPlayerNode()
        engine.attach(node)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(node, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            return
        }

        let frameCount = AVAudioFrameCount(format.sampleRate * 0.1)
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) {
            buffer.frameLength = frameCount
            node.scheduleBuffer(buffer, at: nil, options: .loops)
            node.volume = 0
            node.play()
            isRunning = true
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
    }
}
