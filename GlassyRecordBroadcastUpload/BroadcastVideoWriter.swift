@preconcurrency import AVFoundation
import ReplayKit
import CoreMedia

/// Запись экрана/аудио в Broadcast Extension по практике Apple ReplayKit:
/// H.264 MP4, real-time inputs, чётные размеры кадра.
/// Важно: `finishWriting` ждём ВНЕ writeQueue — иначе возможен deadlock с ReplayKit.
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
    private var isFinishing = false
    private var lastVideoPTS: CMTime = .invalid
    private let videoWidth: Int
    private let videoHeight: Int
    private var lastErrorMessage: String?
    private(set) var micBuffersWritten = 0
    private(set) var appBuffersWritten = 0

    var canAcceptAudio: Bool {
        writeQueue.sync { sessionStarted && !isFinishing && assetWriter?.status == .writing }
    }

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

        // Mic первым: ReplayKit отдаёт mono; многие плееры (Фото) играют только первую аудиодорожку.
        // Раньше stereo system-audio был первым → тишина, а голос во второй дорожке не слышен.
        var sysInput: AVAssetWriterInput?
        var micInput: AVAssetWriterInput?

        if config.microphoneEnabled {
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                micInput = input
            }
        }

        if config.systemAudioEnabled {
            let appSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: appSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                sysInput = input
            }
        }

        assetWriter = writer
        videoInput = vInput
        pixelBufferAdaptor = adaptor
        systemAudioInput = sysInput
        microphoneAudioInput = micInput
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        // Sync обязателен: CMSampleBuffer от ReplayKit невалиден после return из processSampleBuffer.
        writeQueue.sync {
            autoreleasepool {
                guard !isFinishing else { return }
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
                    lastErrorMessage = assetWriter.error?.localizedDescription
                        ?? "writer status=\(assetWriter.status.rawValue)"
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
                guard !isFinishing else { return }
                guard sessionStarted,
                      CMSampleBufferDataIsReady(sampleBuffer),
                      let assetWriter,
                      assetWriter.status == .writing else { return }

                switch type {
                case .audioApp:
                    guard config.systemAudioEnabled,
                          let systemAudioInput,
                          systemAudioInput.isReadyForMoreMediaData else { return }
                    if systemAudioInput.append(sampleBuffer) {
                        appBuffersWritten += 1
                    } else {
                        lastErrorMessage = assetWriter.error?.localizedDescription
                            ?? "Не удалось записать звук приложения"
                    }
                case .audioMic:
                    guard config.microphoneEnabled,
                          let microphoneAudioInput,
                          microphoneAudioInput.isReadyForMoreMediaData else { return }
                    if microphoneAudioInput.append(sampleBuffer) {
                        micBuffersWritten += 1
                    } else {
                        lastErrorMessage = assetWriter.error?.localizedDescription
                            ?? "Не удалось записать микрофон"
                    }
                default:
                    break
                }
            }
        }
    }

    struct FinishResult {
        let success: Bool
        let relativeFileName: String
        let outputURL: URL
        let errorMessage: String?
        let wroteFrames: Bool
        let fileSize: Int
        let micBuffers: Int
        let appBuffers: Int
    }

    func finishSync() -> FinishResult {
        // 1) Закрываем входы на writeQueue, но НЕ ждём finishWriting здесь (deadlock с ReplayKit).
        let prepare: (
            writer: AVAssetWriter?,
            shouldFinish: Bool,
            wroteFrames: Bool,
            errorMessage: String?
        ) = writeQueue.sync {
            isFinishing = true
            guard let assetWriter else {
                return (nil, false, false, lastErrorMessage ?? "Writer не создан")
            }

            guard sessionStarted, didWriteFrames else {
                if assetWriter.status == .writing {
                    videoInput?.markAsFinished()
                    systemAudioInput?.markAsFinished()
                    microphoneAudioInput?.markAsFinished()
                    return (assetWriter, true, false, lastErrorMessage)
                }
                return (assetWriter, false, false, lastErrorMessage ?? "Не получены кадры экрана. Держите запись хотя бы 2–3 секунды.")
            }

            videoInput?.markAsFinished()
            systemAudioInput?.markAsFinished()
            microphoneAudioInput?.markAsFinished()
            if lastVideoPTS.isValid {
                assetWriter.endSession(atSourceTime: lastVideoPTS)
            }
            return (assetWriter, true, true, lastErrorMessage)
        }

        // 2) Ждём finishWriting на потоке SampleHandler, writeQueue свободен для хвоста.
        if let writer = prepare.writer, prepare.shouldFinish, writer.status == .writing {
            let group = DispatchGroup()
            group.enter()
            writer.finishWriting { group.leave() }
            _ = group.wait(timeout: .now() + 15)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        let exists = FileManager.default.fileExists(atPath: outputURL.path)
        let status = prepare.writer?.status
        let writerError = prepare.writer?.error?.localizedDescription

        let micCount = writeQueue.sync { micBuffersWritten }
        let appCount = writeQueue.sync { appBuffersWritten }

        if prepare.wroteFrames, status == .completed, exists, size > 0 {
            return FinishResult(
                success: true,
                relativeFileName: relativeFileName,
                outputURL: outputURL,
                errorMessage: nil,
                wroteFrames: true,
                fileSize: size,
                micBuffers: micCount,
                appBuffers: appCount
            )
        }

        if !prepare.wroteFrames {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let message = writerError
            ?? prepare.errorMessage
            ?? "Файл записи повреждён или пуст (status=\(status?.rawValue ?? -1), size=\(size))"
        return FinishResult(
            success: false,
            relativeFileName: relativeFileName,
            outputURL: outputURL,
            errorMessage: message,
            wroteFrames: prepare.wroteFrames,
            fileSize: size,
            micBuffers: micCount,
            appBuffers: appCount
        )
    }

    private static func transform(forOrientationAttachment orientation: CFTypeRef) -> CGAffineTransform {
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
