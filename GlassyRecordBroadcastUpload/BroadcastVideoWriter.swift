@preconcurrency import AVFoundation
import ReplayKit

/// Запись экрана и аудио в extension. Face Cam — через системный PiP в main app.
final class BroadcastVideoWriter: @unchecked Sendable {
    let outputURL: URL

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneAudioInput: AVAssetWriterInput?
    private let config: BroadcastRecordingConfig
    private let writeQueue = DispatchQueue(label: "com.glassyrecord.broadcast.writer", qos: .userInitiated)
    private var sessionStarted = false
    private var didWriteFrames = false

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

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
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

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

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
        pixelBufferAdaptor = adaptor
        systemAudioInput = sysInput
        microphoneAudioInput = micInput
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        writeQueue.sync {
            guard let videoInput,
                  let pixelBufferAdaptor,
                  let assetWriter,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if !sessionStarted {
                guard assetWriter.startWriting() else { return }
                assetWriter.startSession(atSourceTime: pts)
                sessionStarted = true
            }

            guard pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData else { return }

            if pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: pts) {
                didWriteFrames = true
            } else if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
                didWriteFrames = true
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) {
        writeQueue.sync {
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

    @discardableResult
    func finishSync() -> Bool {
        writeQueue.sync {
            guard sessionStarted, let videoInput, let assetWriter else { return didWriteFrames }
            videoInput.markAsFinished()
            systemAudioInput?.markAsFinished()
            microphoneAudioInput?.markAsFinished()
            let group = DispatchGroup()
            group.enter()
            assetWriter.finishWriting { group.leave() }
            group.wait()
            return didWriteFrames
        }
    }
}
