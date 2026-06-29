@preconcurrency import AVFoundation
@preconcurrency import Combine
@preconcurrency import ReplayKit

private struct UncheckedSendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

private struct UncheckedSendableWriterConfig: @unchecked Sendable {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput?
}

/// Потокобезопасная запись sample buffer — не блокирует main.
private final class CaptureWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.glassyrecord.screenwriter", qos: .userInitiated)
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    func configure(writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?) {
        let config = UncheckedSendableWriterConfig(writer: writer, video: video, audio: audio)
        queue.async { [self] in
            assetWriter = config.writer
            videoInput = config.video
            audioInput = config.audio
        }
    }

    func reset() {
        queue.async { [self] in
            assetWriter = nil
            videoInput = nil
            audioInput = nil
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) {
        let boxed = UncheckedSendableSampleBuffer(value: sampleBuffer)
        queue.async { [self] in
            let sampleBuffer = boxed.value
            guard let writer = assetWriter else { return }
            guard writer.status == .writing || writer.status == .unknown else { return }

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
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.assetWriter?.finishWriting {
                    if let error = self.assetWriter?.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
}

private struct WriterSetup: @unchecked Sendable {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    let url: URL
}

/// Запись экрана через ReplayKit.
@MainActor
final class ScreenRecorderService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isSimulatorMode = SimulatorSupport.isRunning
    @Published private(set) var duration: TimeInterval = 0
    @Published var error: GlassyRecordError?

    private let recorder = RPScreenRecorder.shared()
    private let captureWriter = CaptureWriter()
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
            return try startSimulatorRecording(quality: quality)
        }

        guard recorder.isAvailable else {
            throw GlassyRecordError.screenRecordingDenied
        }

        // AVAssetWriter создаётся off-main — не блокирует UI.
        let setup = try await Task.detached(priority: .userInitiated) {
            try Self.makeWriter(captureSystemAudio: captureSystemAudio, microphoneEnabled: microphoneEnabled)
        }.value

        outputURL = setup.url
        captureWriter.configure(writer: setup.writer, video: setup.videoInput, audio: setup.audioInput)
        recorder.isMicrophoneEnabled = microphoneEnabled

        let writerBox = captureWriter
        try await startCaptureWithTimeout { boxed, bufferType, captureError in
            if captureError != nil { return }
            writerBox.append(boxed.value, type: bufferType)
        }

        startDate = .now
        isRecording = true
        startTimer()
        return setup.url
    }

    func stopRecording() async throws -> URL {
        guard isRecording else {
            throw GlassyRecordError.screenRecordingFailed("Запись не активна")
        }

        if isSimulatorMode {
            return try await stopSimulatorRecording()
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

        try await captureWriter.finish()
        captureWriter.reset()

        isRecording = false
        stopTimer()

        guard let url = outputURL else {
            throw GlassyRecordError.fileNotFound
        }
        return url
    }

    // MARK: - Private

    nonisolated private static func makeWriter(
        captureSystemAudio: Bool,
        microphoneEnabled: Bool
    ) throws -> WriterSetup {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen_\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30
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
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                aInput = input
            }
        }

        return WriterSetup(writer: writer, videoInput: vInput, audioInput: aInput, url: url)
    }

    private func startSimulatorRecording(quality: RecordingQuality) throws -> URL {
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

    private func stopSimulatorRecording() async throws -> URL {
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

    private func startCaptureWithTimeout(
        handler: @escaping @Sendable (UncheckedSendableSampleBuffer, RPSampleBufferType, Error?) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class ResumeBox: @unchecked Sendable {
                var done = false
                let lock = NSLock()
                let continuation: CheckedContinuation<Void, Error>

                init(_ continuation: CheckedContinuation<Void, Error>) {
                    self.continuation = continuation
                }

                func resume(with result: Result<Void, Error>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !done else { return }
                    done = true
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }

            let box = ResumeBox(continuation)

            recorder.startCapture(handler: { sampleBuffer, bufferType, error in
                handler(UncheckedSendableSampleBuffer(value: sampleBuffer), bufferType, error)
            }, completionHandler: { error in
                if let error {
                    box.resume(with: .failure(GlassyRecordError.screenRecordingFailed(error.localizedDescription)))
                } else {
                    box.resume(with: .success(()))
                }
            })

            Task {
                try await Task.sleep(for: .seconds(8))
                box.resume(with: .failure(GlassyRecordError.screenRecordingFailed("Таймаут запуска ReplayKit")))
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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
