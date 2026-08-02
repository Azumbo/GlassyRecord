import CoreImage
import CoreVideo
import Vision

/// Размытие фона за человеком (Vision person segmentation + Core Image).
final class BackgroundBlurProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var level: BackgroundBlurLevel = .off
    private let requestHandler = VNSequenceRequestHandler()
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var cachedMask: CIImage?
    private var frameCounter = 0

    func setLevel(_ level: BackgroundBlurLevel) {
        lock.lock()
        self.level = level
        if level == .off {
            cachedMask = nil
            frameCounter = 0
        }
        lock.unlock()
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let snapshot = lock.withLock { (level: level, mask: cachedMask, frame: frameCounter) }
        guard snapshot.level != .off, snapshot.level.blurRadius > 0 else { return pixelBuffer }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let original = CIImage(cvPixelBuffer: pixelBuffer)

        // Маску обновляем не каждый кадр — экономия CPU на VGA.
        let shouldRefreshMask = snapshot.frame % 2 == 0 || snapshot.mask == nil
        var maskImage = snapshot.mask
        if shouldRefreshMask {
            do {
                try requestHandler.perform([segmentationRequest], on: pixelBuffer)
                if let maskBuffer = segmentationRequest.results?.first?.pixelBuffer {
                    let rawMask = CIImage(cvPixelBuffer: maskBuffer)
                    let scaleX = CGFloat(width) / rawMask.extent.width
                    let scaleY = CGFloat(height) / rawMask.extent.height
                    maskImage = rawMask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                }
            } catch {
                maskImage = snapshot.mask
            }
        }

        guard let mask = maskImage else {
            lock.withLock { frameCounter += 1 }
            return pixelBuffer
        }

        let blurred = original
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: snapshot.level.blurRadius])
            .cropped(to: original.extent)

        let composited = original.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: blurred,
                kCIInputMaskImageKey: mask
            ]
        )

        guard let output = Self.makeBuffer(width: width, height: height) else {
            return pixelBuffer
        }

        ciContext.render(
            composited,
            to: output,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        lock.withLock {
            cachedMask = mask
            frameCounter += 1
        }
        return output
    }

    private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
