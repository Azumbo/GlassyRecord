import AVFoundation
import CoreVideo

enum PiPSampleBufferFactory {
    private static var formatDescription: CMFormatDescription?

    static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        if formatDescription == nil || !matchesFormat(pixelBuffer) {
            formatDescription = makeFormatDescription(for: pixelBuffer)
        }
        guard let formatDescription else { return nil }

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
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    private static func matchesFormat(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let formatDescription else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return dimensions.width == Int32(width) && dimensions.height == Int32(height)
    }

    private static func makeFormatDescription(for pixelBuffer: CVPixelBuffer) -> CMFormatDescription? {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        )
        return description
    }
}
