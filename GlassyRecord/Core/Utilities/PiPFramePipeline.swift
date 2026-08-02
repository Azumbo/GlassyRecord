import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

/// Подаёт кадры камеры в PiP-слой и превью в приложении.
final class PiPFramePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private weak var previewDisplayLayer: AVSampleBufferDisplayLayer?
    private var isStreaming = false
    private var contentScale: CGFloat = 1.0
    /// Размер выходного буфера в пикселях (как у системного PiP).
    private var targetRenderSize: CGSize = PiPDisplayLayerHost.baseRenderSize
    private var glassesEnabled = false
    private weak var glassesService: GlassesOverlayService?
    private let blurProcessor = BackgroundBlurProcessor()
    private var backgroundBlurLevel: BackgroundBlurLevel = .off
    private var frameIndex: Int64 = 0
    private(set) var hasDeliveredFrame = false
    var onFirstFrame: (() -> Void)?

    private let processQueue = DispatchQueue(label: "com.glassyrecord.pip.process", qos: .userInitiated)
    private let enqueueQueue = DispatchQueue(label: "com.glassyrecord.pip.enqueue", qos: .userInteractive)

    func bind(displayLayer: AVSampleBufferDisplayLayer) {
        lock.withLock { self.displayLayer = displayLayer }
    }

    func bindPreview(displayLayer: AVSampleBufferDisplayLayer) {
        lock.withLock { self.previewDisplayLayer = displayLayer }
    }

    func configure(
        contentScale: CGFloat,
        glassesEnabled: Bool,
        glassesService: GlassesOverlayService?,
        backgroundBlurLevel: BackgroundBlurLevel? = nil
    ) {
        lock.withLock {
            self.contentScale = contentScale
            self.glassesEnabled = glassesEnabled
            self.glassesService = glassesService
            if let backgroundBlurLevel {
                self.backgroundBlurLevel = backgroundBlurLevel
                blurProcessor.setLevel(backgroundBlurLevel)
            }
        }
    }

    func setBackgroundBlurLevel(_ level: BackgroundBlurLevel) {
        lock.withLock {
            backgroundBlurLevel = level
            blurProcessor.setLevel(level)
        }
    }

    func setTargetRenderSize(_ pixelSize: CGSize) {
        lock.withLock {
            let changed = abs(targetRenderSize.width - pixelSize.width) > 1
                || abs(targetRenderSize.height - pixelSize.height) > 1
            targetRenderSize = pixelSize
            if changed {
                PiPSampleBufferFactory.reset()
            }
        }
    }

    func start() {
        lock.withLock {
            isStreaming = true
            frameIndex = 0
            hasDeliveredFrame = false
        }
    }

    func stop() {
        lock.withLock { isStreaming = false }
    }

    func process(pixelBuffer: CVPixelBuffer) {
        let snapshot = lock.withLock {
            (
                isStreaming: isStreaming,
                targetRenderSize: targetRenderSize,
                glassesEnabled: glassesEnabled,
                glassesService: glassesService,
                blurLevel: backgroundBlurLevel,
                displayLayer: displayLayer,
                previewDisplayLayer: previewDisplayLayer
            )
        }
        guard snapshot.isStreaming, snapshot.displayLayer != nil || snapshot.previewDisplayLayer != nil else {
            return
        }

        processQueue.async { [weak self] in
            guard let self else { return }
            guard self.lock.withLock({ self.isStreaming }) else { return }

            var finalBuffer = pixelBuffer

            // blur → glasses → scale: очки остаются чёткими на лице.
            if snapshot.blurLevel != .off {
                finalBuffer = self.blurProcessor.processFrame(finalBuffer)
            }

            if snapshot.glassesEnabled, let service = snapshot.glassesService {
                finalBuffer = service.processFrame(finalBuffer)
            }

            let targetSize = self.lock.withLock { self.targetRenderSize }
            let zoom = self.lock.withLock { self.contentScale }
            finalBuffer = PiPFrameScaler.scale(
                finalBuffer,
                targetSize: targetSize,
                contentZoom: zoom
            )

            let index = self.lock.withLock {
                let current = self.frameIndex
                self.frameIndex += 1
                return current
            }
            let pts = CMTime(value: index, timescale: 30)

            guard let sample = PiPSampleBufferFactory.makeSampleBuffer(from: finalBuffer, presentationTime: pts) else {
                return
            }

            self.enqueueQueue.async { [weak self] in
                let layers = [snapshot.displayLayer, snapshot.previewDisplayLayer].compactMap { $0 }
                for layer in layers {
                    self?.enqueue(sample, to: layer)
                }

                guard let self else { return }
                let shouldNotify = self.lock.withLock {
                    guard !self.hasDeliveredFrame else { return false }
                    self.hasDeliveredFrame = true
                    return true
                }
                if shouldNotify {
                    DispatchQueue.main.async {
                        self.onFirstFrame?()
                    }
                }
            }
        }
    }

    private func enqueue(_ sample: CMSampleBuffer, to layer: AVSampleBufferDisplayLayer) {
        guard layer.isReadyForMoreMediaData else { return }

        if layer.status == .failed {
            layer.flush()
        }
        if #available(iOS 14.0, *), layer.requiresFlushToResumeDecoding {
            layer.flush()
        }

        layer.enqueue(sample)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
