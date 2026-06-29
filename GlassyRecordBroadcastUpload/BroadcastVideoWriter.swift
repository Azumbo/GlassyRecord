@preconcurrency import AVFoundation
import ReplayKit

private struct UncheckedSendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

/// Запись экрана и аудио в extension. Face Cam — через системный PiP в main app.
final class BroadcastVideoWriter: @unchecked Sendable {
    let outputURL: URL

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneAudioInput: AVAssetWriterInput?
    private let config: BroadcastRecordingConfig
    private let writeQueue = DispatchQueue(label: "com.glassyrecord.broadcast.writer", qos: .utility)
    private var sessionStarted = false
    private(set) var didWriteFrames = false
    private var poolWidth = 0
    private var poolHeight = 0

    init(
        outputURL: URL,
        config: BroadcastRecordingConfig,
        firstSample: CMSampleBuffer
    ) throws {
        self.outputURL = outputURL
        self.config = config

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(firstSample) else {
            throw NSError(domain: "Writer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No pixel buffer"])
        }

        poolWidth = CVPixelBufferGetWidth(pixelBuffer)
        poolHeight = CVPixelBufferGetHeight(pixelBuffer)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: poolWidth,
            AVVideoHeightKey: poolHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vInput) else {
            throw NSError(domain: "Writer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add video"])
        }
        writer.add(vInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]

        var sysInput: AVAssetWriterInput?
        var micInput: AVAssetWriterInput?

        if config.systemAudioEnabled {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                sysInput = input
            }
        }

        if config.microphoneEnabled {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                micInput = input
            }
        }

        assetWriter = writer
        videoInput = vInput
        systemAudioInput = sysInput
        microphoneAudioInput = micInput
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        let boxed = UncheckedSendableSampleBuffer(value: sampleBuffer)
        writeQueue.async { [self] in
            let sampleBuffer = boxed.value
            guard let videoInput, let assetWriter else { return }
            guard videoInput.isReadyForMoreMediaData else { return }

            if !sessionStarted {
                assetWriter.startWriting()
                assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                sessionStarted = true
            }

            if videoInput.append(sampleBuffer) {
                didWriteFrames = true
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) {
        let boxed = UncheckedSendableSampleBuffer(value: sampleBuffer)
        writeQueue.async { [self] in
            let sampleBuffer = boxed.value
            guard sessionStarted else { return }

            switch type {
            case .audioApp:
                guard config.systemAudioEnabled,
                      let systemAudioInput,
                      systemAudioInput.isReadyForMoreMediaData else { return }
                systemAudioInput.append(sampleBuffer)
            case .audioMic:
                guard config.microphoneEnabled,
                      let microphoneAudioInput,
                      microphoneAudioInput.isReadyForMoreMediaData else { return }
                microphoneAudioInput.append(sampleBuffer)
            default:
                break
            }
        }
    }

    func finishSync() {
        writeQueue.sync {
            guard sessionStarted, let videoInput, let assetWriter else { return }
            videoInput.markAsFinished()
            systemAudioInput?.markAsFinished()
            microphoneAudioInput?.markAsFinished()
            let group = DispatchGroup()
            group.enter()
            assetWriter.finishWriting { group.leave() }
            group.wait()
        }
    }
}
