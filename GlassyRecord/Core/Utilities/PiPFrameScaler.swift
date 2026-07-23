import CoreImage
import CoreVideo
import UIKit

/// Потокобезопасный ресайз кадров камеры в фиксированный PiP-буфер.
/// `contentZoom` — крупность лица: всегда aspect-fill (без чёрных полей), >1 ближе.
enum PiPFrameScaler: @unchecked Sendable {
    private static let lock = NSLock()
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Всегда пишет в `targetSize` с заполнением кадра. Зум только меняет кроп, не добавляет letterbox.
    static func scale(
        _ pixelBuffer: CVPixelBuffer,
        targetSize: CGSize,
        contentZoom: CGFloat
    ) -> CVPixelBuffer {
        let width = Int(targetSize.width.rounded(.toNearestOrAwayFromZero))
        let height = Int(targetSize.height.rounded(.toNearestOrAwayFromZero))
        guard width > 0, height > 0 else { return pixelBuffer }

        // Ниже 1.0 = «отдалиться» нельзя без полей: оставляем минимум aspect-fill (1.0).
        let zoom = min(max(contentZoom, 1.0), 2.5)
        let srcWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let srcHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard srcWidth > 1, srcHeight > 1 else { return pixelBuffer }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let target = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))

        let fill = max(target.width / srcWidth, target.height / srcHeight) * zoom
        let scaled = source.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let extent = scaled.extent
        let crop = CGRect(
            x: extent.midX - target.width / 2,
            y: extent.midY - target.height / 2,
            width: target.width,
            height: target.height
        )
        let rendered = scaled.cropped(to: crop).transformed(
            by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y)
        )

        guard let output = createOutputBuffer(width: width, height: height) else {
            return pixelBuffer
        }

        lock.lock()
        ciContext.render(
            rendered,
            to: output,
            bounds: target,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        lock.unlock()
        return output
    }

    private static func createOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
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
        guard status == kCVReturnSuccess else { return nil }
        return output
    }
}
