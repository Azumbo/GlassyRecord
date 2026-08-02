import AVFoundation
import Combine

/// Управление аудиодорожками: микрофон и системный звук.
@MainActor
final class AudioService: ObservableObject {
    @Published var microphoneVolume: Float = 1.0
    @Published var systemAudioVolume: Float = 1.0
    @Published private(set) var microphoneLevel: Float = 0
    @Published var error: GlassyRecordError?

    private var audioEngine: AVAudioEngine?
    private var levelTimer: Timer?

    func ensureMicrophonePermission(enabled: Bool) async throws {
        guard enabled else { return }

        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            granted = false
        }

        guard granted else {
            throw GlassyRecordError.permissionDenied("микрофону")
        }
    }

    func configure(microphoneEnabled: Bool) async throws {
        try await ensureMicrophonePermission(enabled: microphoneEnabled)

        try AVAudioSession.sharedInstance().setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
        )
        try AVAudioSession.sharedInstance().setActive(true)
    }

    func startLevelMonitoring() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames {
                sum += abs(channelData[i])
            }
            let avg = sum / Float(frames)
            Task { @MainActor [weak self] in
                self?.microphoneLevel = min(1, avg * 10)
            }
        }

        do {
            try engine.start()
            audioEngine = engine
        } catch {
            self.error = .microphoneUnavailable
        }
    }

    func stopLevelMonitoring() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        microphoneLevel = 0
    }

    /// Применяет громкость к аудиодорожке при экспорте.
    func applyVolume(to asset: AVAsset, micVolume: Float, systemVolume: Float) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        for (index, track) in audioTracks.enumerated() {
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            let duration = try await asset.load(.duration)
            try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)

            let volume = index == 0 ? micVolume : systemVolume
            compTrack.preferredVolume = volume
        }

        return composition
    }
}
