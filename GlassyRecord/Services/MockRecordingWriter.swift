import AVFoundation
import UIKit

/// Создаёт короткий тестовый MP4 для симулятора (ReplayKit там недоступен).
enum MockRecordingWriter {
    static func createSampleVideo(
        quality: RecordingQuality,
        duration: TimeInterval
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim_recording_\(UUID().uuidString).mp4")

        let width = Int(quality.resolution.width / 4)  // меньше для скорости на симуляторе
        let height = Int(quality.resolution.height / 4)
        let fps: Int32 = 30
        let frameCount = max(1, Int(duration * Double(fps)))

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.canAdd(input) else {
            throw GlassyRecordError.exportFailed(L10n.t("error.mock_video_failed"))
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            if let buffer = makeFrame(width: width, height: height, index: frame) {
                adaptor.append(buffer, withPresentationTime: time)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()

        if writer.status != .completed {
            throw GlassyRecordError.exportFailed(writer.error?.localizedDescription ?? L10n.t("error.writer_failed"))
        }
        return url
    }

    private static func makeFrame(width: Int, height: Int, index: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &buffer
        )
        guard let pixelBuffer = buffer,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let hue = CGFloat(index % 60) / 60.0
        let color = UIColor(hue: hue, saturation: 0.35, brightness: 0.25, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                ptr[offset] = UInt8(b * 255)
                ptr[offset + 1] = UInt8(g * 255)
                ptr[offset + 2] = UInt8(r * 255)
                ptr[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}
