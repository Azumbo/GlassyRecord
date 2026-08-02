import AVFoundation
import Combine

/// Управление аудиодорожками + Zoom-подобные тесты mic / speaker в настройках.
@MainActor
final class AudioService: ObservableObject {
    @Published var microphoneVolume: Float = 1.0
    @Published var systemAudioVolume: Float = 1.0
    /// 0…1 после сглаживания; учитывает `microphoneVolume`.
    @Published private(set) var microphoneLevel: Float = 0
    /// 0…1 во время теста динамика; учитывает `systemAudioVolume`.
    @Published private(set) var speakerLevel: Float = 0
    @Published private(set) var isTestingMicrophone = false
    @Published private(set) var isTestingSpeaker = false
    @Published var error: GlassyRecordError?

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var smoothedMic: Float = 0
    private var speakerStopTask: Task<Void, Never>?

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
            throw GlassyRecordError.permissionDenied(L10n.t("permission.microphone"))
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

    // MARK: - Mic test (level meter)

    func startMicrophoneTest() async {
        stopSpeakerTest()
        stopLevelMonitoring()

        do {
            try await ensureMicrophonePermission(enabled: true)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)
        } catch {
            self.error = .permissionDenied(L10n.t("permission.microphone"))
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.error = .microphoneUnavailable
            releaseAudioSession()
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            var sumSquares: Float = 0
            var peak: Float = 0
            for i in 0..<frames {
                let sample = channelData[i]
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
            }
            let rms = sqrt(sumSquares / Float(frames))
            // Типичный разговор ~0.01–0.1 RMS; шкалу делаем читаемой как в Zoom.
            let normalized = min(1, max(rms * 12, peak * 2.2))

            Task { @MainActor [weak self] in
                guard let self, self.isTestingMicrophone else { return }
                self.smoothedMic = self.smoothedMic * 0.65 + normalized * 0.35
                let gain = max(0.05, self.microphoneVolume)
                self.microphoneLevel = min(1, self.smoothedMic * gain)
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            isTestingMicrophone = true
            error = nil
        } catch {
            self.error = .microphoneUnavailable
            releaseAudioSession()
        }
    }

    func stopLevelMonitoring() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        playerNode = nil
        isTestingMicrophone = false
        smoothedMic = 0
        microphoneLevel = 0
    }

    func stopMicrophoneTest() {
        stopLevelMonitoring()
        releaseAudioSession()
    }

    // MARK: - Speaker test

    func playSpeakerTest() {
        stopMicrophoneTest()
        speakerStopTask?.cancel()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            self.error = .microphoneUnavailable
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let sampleRate: Double = 44_100
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = min(1, max(0.05, systemAudioVolume))

        guard let buffer = Self.makeTestToneBuffer(sampleRate: sampleRate, duration: 1.6) else {
            releaseAudioSession()
            return
        }

        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.finishSpeakerTest()
                }
            }
            player.play()
            audioEngine = engine
            playerNode = player
            isTestingSpeaker = true
            animateSpeakerMeter(duration: 1.6)
        } catch {
            self.error = .microphoneUnavailable
            releaseAudioSession()
        }
    }

    func stopSpeakerTest() {
        speakerStopTask?.cancel()
        speakerStopTask = nil
        playerNode?.stop()
        playerNode = nil
        if !isTestingMicrophone {
            audioEngine?.stop()
            audioEngine = nil
        }
        isTestingSpeaker = false
        speakerLevel = 0
        if !isTestingMicrophone {
            releaseAudioSession()
        }
    }

    func stopAllTests() {
        stopMicrophoneTest()
        stopSpeakerTest()
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

    // MARK: - Private

    private func finishSpeakerTest() {
        playerNode?.stop()
        playerNode = nil
        audioEngine?.stop()
        audioEngine = nil
        isTestingSpeaker = false
        speakerLevel = 0
        releaseAudioSession()
    }

    private func animateSpeakerMeter(duration: TimeInterval) {
        speakerStopTask?.cancel()
        speakerStopTask = Task { @MainActor in
            let steps = 32
            let stepSleep = duration / Double(steps)
            for i in 0..<steps {
                if Task.isCancelled { break }
                // Пульс «звуковой волны» + лёгкий envelope атаки/затухания.
                let t = Double(i) / Double(steps - 1)
                let envelope = sin(t * .pi)
                let pulse = 0.55 + 0.45 * abs(sin(t * .pi * 6))
                speakerLevel = Float(envelope * pulse) * min(1, max(0.15, systemAudioVolume))
                try? await Task.sleep(for: .seconds(stepSleep))
            }
            if !Task.isCancelled {
                speakerLevel = 0
            }
        }
    }

    private func releaseAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Короткий двухтональный сигнал (как «test speaker»).
    private static func makeTestToneBuffer(sampleRate: Double, duration: TimeInterval) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData?[0] else { return nil }

        let twoPi = 2.0 * Double.pi
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope: Double
            if t < 0.04 {
                envelope = t / 0.04
            } else if t > duration - 0.12 {
                envelope = max(0, (duration - t) / 0.12)
            } else {
                envelope = 1
            }
            // 880 Hz → 1174 Hz (приятный «ding»).
            let freq = t < duration * 0.45 ? 880.0 : 1174.6
            let sample = sin(twoPi * freq * t) * envelope * 0.35
            data[i] = Float(sample)
        }
        return buffer
    }
}
