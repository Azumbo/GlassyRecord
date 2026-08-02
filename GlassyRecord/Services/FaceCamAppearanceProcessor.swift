import CoreImage
import CoreVideo

/// Эффекты Appearance для Face Cam: touch-up, low light, portrait lighting.
final class FaceCamAppearanceProcessor: @unchecked Sendable {
    struct Settings: Equatable {
        var touchUpEnabled: Bool = false
        var touchUpStrength: Float = 0.35
        var lowLightEnabled: Bool = false
        var portraitLightingEnabled: Bool = false

        var isActive: Bool {
            touchUpEnabled || lowLightEnabled || portraitLightingEnabled
        }
    }

    private let lock = NSLock()
    private var settings = Settings()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func update(_ settings: Settings) {
        lock.lock()
        self.settings = settings
        lock.unlock()
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let snapshot = lock.withLock { settings }
        guard snapshot.isActive else { return pixelBuffer }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent

        if snapshot.lowLightEnabled {
            image = image
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.4])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: 0.04,
                    kCIInputContrastKey: 1.04,
                    kCIInputSaturationKey: 1.05
                ])
        }

        if snapshot.touchUpEnabled {
            let amount = CGFloat(max(0, min(1, snapshot.touchUpStrength)))
            let soft = image
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.8 + amount * 2.8])
                .cropped(to: extent)
            // Dissolve: 0 = оригинал, 1 = сглаженный (доступно на iOS 16).
            let mixAmount = amount * 0.65
            image = image
                .applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: soft,
                    kCIInputTimeKey: mixAmount
                ])
                .cropped(to: extent)
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.0 + amount * 0.06,
                kCIInputBrightnessKey: amount * 0.015
            ])
        }

        if snapshot.portraitLightingEnabled {
            image = image
                .applyingFilter("CIVignette", parameters: [
                    kCIInputRadiusKey: 1.4,
                    kCIInputIntensityKey: 0.45
                ])
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 5600, y: 20)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.06,
                    kCIInputSaturationKey: 1.03
                ])
        }

        guard let output = Self.makeBuffer(width: width, height: height) else {
            return pixelBuffer
        }
        ciContext.render(
            image,
            to: output,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
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
