import CoreGraphics
import CoreVideo
import UIKit

/// Генерирует кадры-заглушки для Face Cam на симуляторе.
@MainActor
final class MockCameraFeed: ObservableObject {
    @Published private(set) var isRunning = false

    private var timer: Timer?
    private var frameHandler: ((CVPixelBuffer) -> Void)?
    private let size = CGSize(width: 640, height: 480)

    func onFrame(_ handler: @escaping (CVPixelBuffer) -> Void) {
        frameHandler = handler
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        emitFrame()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitFrame() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    private func emitFrame() {
        guard let buffer = makePlaceholderPixelBuffer() else { return }
        frameHandler?(buffer)
    }

    private func makePlaceholderPixelBuffer() -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer
        ) == kCVReturnSuccess,
        let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Фон «комнаты»
        let colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: width, y: height),
                options: []
            )
        }

        // Силуэт лица
        let faceRect = CGRect(
            x: CGFloat(width) * 0.28,
            y: CGFloat(height) * 0.18,
            width: CGFloat(width) * 0.44,
            height: CGFloat(height) * 0.62
        )
        context.setFillColor(UIColor.systemPink.withAlphaComponent(0.55).cgColor)
        context.fillEllipse(in: faceRect)

        // Глаза
        context.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        let eyeY = faceRect.midY - faceRect.height * 0.08
        let eyeW = faceRect.width * 0.18
        let eyeH = faceRect.height * 0.1
        context.fillEllipse(in: CGRect(x: faceRect.minX + faceRect.width * 0.18, y: eyeY, width: eyeW, height: eyeH))
        context.fillEllipse(in: CGRect(x: faceRect.maxX - faceRect.width * 0.18 - eyeW, y: eyeY, width: eyeW, height: eyeH))

        return buffer
    }
}
