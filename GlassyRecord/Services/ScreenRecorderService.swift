import AVFoundation
import Combine
import ReplayKit

/// Запись экрана через ReplayKit с поддержкой системного звука.
/// На симуляторе — таймер + тестовый MP4 через `MockRecordingWriter`.
@MainActor
final class ScreenRecorderService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isSimulatorMode = SimulatorSupport.isRunning
    @Published private(set) var duration: TimeInterval = 0
    @Published var error: GlassyRecordError?

    private let recorder = RPScreenRecorder.shared()
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var timer: Timer?
    private var startDate: Date?
    private var simulatorQuality: RecordingQuality = .hd1080p

    func startRecording(
        quality: RecordingQuality,
        captureSystemAudio: Bool,
        microphoneEnabled: Bool
    ) async throws -> URL {
        if SimulatorSupport.isRunning {
            simulatorQuality = quality
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("sim_screen_\(UUID().uuidString).mp4")
            outputURL = url
            startDate = .now
            isRecording = true
            isSimulatorMode = true
            startTimer()
            return url
        }

        guard recorder.isAvailable else {
            throw GlassyRecordError.screenRecordingDenied
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen_\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(quality.resolution.width),
            AVVideoHeightKey: Int(quality.resolution.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality == .uhd4K ? 20_000_000 : 8_000_000,
                AVVideoMaxKeyFrameIntervalKey: quality.preferredFPS
            ]
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(vInput) else {
            throw GlassyRecordError.screenRecordingFailed("Не удалось добавить видеодорожку")
        }
        writer.add(vInput)

        var aInput: AVAssetWriterInput?
        if captureSystemAudio || microphoneEnabled {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                aInput = input
            }
        }

        assetWriter = writer
        videoInput = vInput
        audioInput = aInput
        outputURL = url

        recorder.isMicrophoneEnabled = microphoneEnabled

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.startCapture(handler: { [weak self] sampleBuffer, bufferType, error in
                guard let self else { return }
                if let error {
                    Task { @MainActor in
                        self.error = .screenRecordingFailed(error.localizedDescription)
                    }
                    return
                }
                self.handleSampleBuffer(sampleBuffer, type: bufferType)
            }, completionHandler: { error in
                if let error {
                    continuation.resume(throwing: GlassyRecordError.screenRecordingFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }

        startDate = .now
        isRecording = true
        startTimer()
        return url
    }

    func stopRecording() async throws -> URL {
        guard isRecording else { throw GlassyRecordError.screenRecordingFailed("Запись не активна") }

        if isSimulatorMode {
            let recordedDuration = max(duration, 1)
            stopTimer()
            isRecording = false
            let url = try await MockRecordingWriter.createSampleVideo(
                quality: simulatorQuality,
                duration: recordedDuration
            )
            outputURL = url
            return url
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.stopCapture { error in
                if let error {
                    continuation.resume(throwing: GlassyRecordError.screenRecordingFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await assetWriter?.finishWriting()

        isRecording = false
        stopTimer()

        guard let url = outputURL else { throw GlassyRecordError.fileNotFound }
        return url
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) {
        guard let writer = assetWriter, writer.status == .writing || writer.status == .unknown else { return }

        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }

        switch type {
        case .video:
            if videoInput?.isReadyForMoreMediaData == true {
                videoInput?.append(sampleBuffer)
            }
        case .audioApp, .audioMic:
            if audioInput?.isReadyForMoreMediaData == true {
                audioInput?.append(sampleBuffer)
            }
        @unknown default:
            break
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startDate else { return }
                self.duration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        duration = 0
        startDate = nil
    }
}
