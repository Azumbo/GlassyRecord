@preconcurrency import AVFoundation
import ReplayKit
import CoreMedia

/// Запись экрана/аудио в Broadcast Extension по практике Apple ReplayKit:
/// H.264 MP4, real-time inputs, чётные размеры кадра, блокирующий finishWriting.
final class BroadcastVideoWriter: @unchecked Sendable {
    let outputURL: URL
    let relativeFileName: String

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneAudioInput: AVAssetWriterInput?
    private let config: BroadcastRecordingConfig
    private let writeQueue = DispatchQueue(label: "com.glassyrecord.broadcast.writer", qos: .userInitiated)
    private var sessionStarted = false
    private var didWriteFrames = false
    private var lastVideoPTS: CMTime = .invalid
    private let videoWidth: Int
    private let videoHeight: Int
    private(set) var lastErrorMessage: String?

    init(
        outputURL: URL,
        relativeFileName: String,
        config: BroadcastRecordingConfig,
        firstSample: CMSampleBuffer
    ) throws {
        self.outputURL = outputURL
        self.relativeFileName = relativeFileName
        self.config = config

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(firstSample) else {
            throw NSError(domain: "Writer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Нет pixel buffer от ReplayKit"])
        }

        // H.264 требует чётные width/height. У iPhone часто нечётная ширина (напр. 1179).
        let rawWidth = CVPixelBufferGetWidth(pixelBuffer)
        let rawHeight = CVPixelBufferGetHeight(pixelBuffer)
        self.videoWidth = max(rawWidth & ~1, 2)
        self.videoHeight = max(rawHeight & ~1, 2)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false

        let bitrate = max(2_500_000, videoWidth * videoHeight * 4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        if let orientation = CMGetAttachment(
            firstSample,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) {
            vInput.transform = Self.transform(forOrientationAttachment: orientation)
        }
        guard writer.canAdd(vInput) else {
            throw NSError(domain: "Writer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось добавить video input"])
        }
        writer.add(vInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
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
            autoreleasepool {
                guard let videoInput,
                      let pixelBufferAdaptor,
                      let assetWriter,
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                      CMSampleBufferDataIsReady(sampleBuffer) else { return }

                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard pts.isValid, pts.isNumeric else { return }

                if !sessionStarted {
                    guard assetWriter.startWriting() else {
                        lastErrorMessage = assetWriter.error?.localizedDescription ?? "startWriting failed"
                        return
                    }
                    assetWriter.startSession(atSourceTime: pts)
                    sessionStarted = true
                }

                guard assetWriter.status == .writing else {
                    lastErrorMessage = assetWriter.error?.localizedDescription ?? "writer status=\(assetWriter.status.rawValue)"
                    return
                }
                guard videoInput.isReadyForMoreMediaData else { return }

                let appended: Bool
                let srcW = CVPixelBufferGetWidth(pixelBuffer)
                let srcH = CVPixelBufferGetHeight(pixelBuffer)
                if srcW == videoWidth, srcH == videoHeight {
                    appended = pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: pts)
                        || videoInput.append(sampleBuffer)
                } else if let cropped = Self.copyPixelBuffer(pixelBuffer, width: videoWidth, height: videoHeight) {
                    appended = pixelBufferAdaptor.append(cropped, withPresentationTime: pts)
                } else {
                    appended = videoInput.append(sampleBuffer)
                }

                if appended {
                    didWriteFrames = true
                    lastVideoPTS = pts
                } else if let error = assetWriter.error {
                    lastErrorMessage = error.localizedDescription
                } else {
                    lastErrorMessage = "Не удалось записать видеокадр"
                }
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) {
        writeQueue.sync {
            autoreleasepool {
                guard sessionStarted,
                      CMSampleBufferDataIsReady(sampleBuffer),
                      let assetWriter,
                      assetWriter.status == .writing else { return }

                switch type {
                case .audioApp:
                    guard config.systemAudioEnabled,
                          let systemAudioInput,
                          systemAudioInput.isReadyForMoreMediaData else { return }
                    _ = systemAudioInput.append(sampleBuffer)
                case .audioMic:
                    guard config.microphoneEnabled,
                          let microphoneAudioInput,
                          microphoneAudioInput.isReadyForMoreMediaData else { return }
                    _ = microphoneAudioInput.append(sampleBuffer)
                default:
                    break
                }
            }
        }
    }

    /// Результат финализации: успех только если writer completed и файл на диске.
    struct FinishResult {
        let success: Bool
        let relativeFileName: String
        let outputURL: URL
        let errorMessage: String?
    }

    func finishSync() -> FinishResult {
        writeQueue.sync {
            guard let assetWriter else {
                return FinishResult(
                    success: false,
                    relativeFileName: relativeFileName,
                    outputURL: outputURL,
                    errorMessage: lastErrorMessage ?? "Writer не создан"
                )
            }

            guard sessionStarted, didWriteFrames else {
                if assetWriter.status == .writing {
                    videoInput?.markAsFinished()
                    systemAudioInput?.markAsFinished()
                    microphoneAudioInput?.markAsFinished()
                    let group = DispatchGroup()
                    group.enter()
                    assetWriter.finishWriting { group.leave() }
                    group.wait()
                }
                try? FileManager.default.removeItem(at: outputURL)
                return FinishResult(
                    success: false,
                    relativeFileName: relativeFileName,
                    outputURL: outputURL,
                    errorMessage: lastErrorMessage ?? "Не получены кадры экрана. Держите запись хотя бы 2–3 секунды."
                )
            }

            videoInput?.markAsFinished()
            systemAudioInput?.markAsFinished()
            microphoneAudioInput?.markAsFinished()
            if lastVideoPTS.isValid {
                assetWriter.endSession(atSourceTime: lastVideoPTS)
            }

            let group = DispatchGroup()
            group.enter()
            assetWriter.finishWriting { group.leave() }
            _ = group.wait(timeout: .now() + 20)

            let completed = assetWriter.status == .completed
            let exists = FileManager.default.fileExists(atPath: outputURL.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0

            if completed, exists, size > 0 {
                return FinishResult(
                    success: true,
                    relativeFileName: relativeFileName,
                    outputURL: outputURL,
                    errorMessage: nil
                )
            }

            let message = assetWriter.error?.localizedDescription
                ?? lastErrorMessage
                ?? "Файл записи повреждён или пуст (status=\(assetWriter.status.rawValue), size=\(size))"
            return FinishResult(
                success: false,
                relativeFileName: relativeFileName,
                outputURL: outputURL,
                errorMessage: message
            )
        }
    }

    private static func transform(forOrientationAttachment orientation: CFTypeRef) -> CGAffineTransform {
        // ReplayKit передаёт CGImagePropertyOrientation как NSNumber.
        let value = (orientation as? NSNumber)?.uint32Value ?? CGImagePropertyOrientation.up.rawValue
        switch CGImagePropertyOrientation(rawValue: value) {
        case .down, .downMirrored:
            return CGAffineTransform(rotationAngle: .pi)
        case .left, .leftMirrored:
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .right, .rightMirrored:
            return CGAffineTransform(rotationAngle: -.pi / 2)
        default:
            return .identity
        }
    }

    private static func copyPixelBuffer(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let output else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let copyWidth = min(width, CVPixelBufferGetWidth(source))
        let copyHeight = min(height, CVPixelBufferGetHeight(source))
        let srcBytes = CVPixelBufferGetBytesPerRow(source)
        let dstBytes = CVPixelBufferGetBytesPerRow(output)
        let rowBytes = min(srcBytes, dstBytes, copyWidth * 4)

        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(output) else { return nil }

        for row in 0..<copyHeight {
            memcpy(dstBase.advanced(by: row * dstBytes), srcBase.advanced(by: row * srcBytes), rowBytes)
        }
        return output
    }
}
