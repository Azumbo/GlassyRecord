import CoreImage
import CoreVideo
import UIKit

/// Потокобезопасный ресайз кадров камеры в физический размер PiP-буфера.
enum PiPFrameScaler: @unchecked Sendable {
    private static let lock = NSLock()
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Создаёт CVPixelBuffer с заданными физическими размерами (aspect fill + center crop).
    static func scale(_ pixelBuffer: CVPixelBuffer, targetSize: CGSize) -> CVPixelBuffer {
        let target = targetSize
        let width = Int(target.width)
        let height = Int(target.height)
        guard width > 0, height > 0 else { return pixelBuffer }

        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)

        let source = CIImage(cvPixelBuffer: pixelBuffer)

        let fillScale = max(target.width / CGFloat(srcWidth), target.height / CGFloat(srcHeight))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        let extent = scaled.extent

        let cropRect = CGRect(
            x: extent.midX - target.width / 2,
            y: extent.midY - target.height / 2,
            width: target.width,
            height: target.height
        )
        let cropped = scaled.cropped(to: cropRect)

        guard let output = createOutputBuffer(width: width, height: height) else {
            return pixelBuffer
        }

        lock.lock()
        ciContext.render(cropped, to: output)
        lock.unlock()
        return output
    }

    private static func createOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess else { return nil }
        return output
    }
}
