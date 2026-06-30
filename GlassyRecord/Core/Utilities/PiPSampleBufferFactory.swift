import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Создаёт CMSampleBuffer для PiP; потокобезопасна для фоновой очереди пайплайна.
enum PiPSampleBufferFactory: @unchecked Sendable {
    private static let lock = NSLock()
    private static var formatDescription: CMFormatDescription?
    private static var cachedWidth: Int32 = 0
    private static var cachedHeight: Int32 = 0

    static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))

        let format = lock.withLock { () -> CMFormatDescription? in
            if formatDescription == nil || !matchesFormat(width: width, height: height) {
                formatDescription = makeFormatDescription(for: pixelBuffer)
                cachedWidth = width
                cachedHeight = height
            }
            return formatDescription
        }

        guard let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           let dict = (attachments as NSArray).firstObject as? NSMutableDictionary {
            dict[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }
        return sampleBuffer
    }

    static func reset() {
        lock.withLock {
            formatDescription = nil
            cachedWidth = 0
            cachedHeight = 0
        }
    }

    private static func matchesFormat(width: Int32, height: Int32) -> Bool {
        guard formatDescription != nil else { return false }
        return cachedWidth == width && cachedHeight == height
    }

    private static func makeFormatDescription(for pixelBuffer: CVPixelBuffer) -> CMFormatDescription? {
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        )
        guard status == noErr else { return nil }
        return description
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
