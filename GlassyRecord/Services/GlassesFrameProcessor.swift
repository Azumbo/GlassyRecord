import ARKit
import CoreVideo
import SceneKit
import UIKit
import Vision

/// Потокобезопасный рендер очков (Vision + SceneKit) для PiP и фоновых очередей захвата.
final class GlassesFrameProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var isEnabled = false
    private var useVisionFallback = true
    private var trackingState = FaceTrackingState()
    private var frameColor: GlassesFrameColor = .red
    private var lensTransparency: Float = 0.85
    private var frameBrightness: Float = 1.0

    private let sceneRenderer: SCNRenderer
    private let scene = SCNScene()
    private var glassesNode: SCNNode?
    private var redGlassesNode: SCNNode?
    private var blueGlassesNode: SCNNode?
    private var visionSequenceHandler = VNSequenceRequestHandler()
    private var smoothedVisionTransform = matrix_identity_float4x4
    private var hasSmoothedVisionTransform = false

    init() {
        let device = MTLCreateSystemDefaultDevice()
        sceneRenderer = SCNRenderer(device: device, options: nil)
        sceneRenderer.scene = scene
        sceneRenderer.autoenablesDefaultLighting = true

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)
        sceneRenderer.pointOfView = cameraNode

        redGlassesNode = GlassesOverlayService.buildMonokolMK295(color: .red, brightness: 1.0)
        blueGlassesNode = GlassesOverlayService.buildMonokolMK295(color: .blue, brightness: 1.0)
        swapGlassesModel(to: .red, locked: true)
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { isEnabled = enabled }
    }

    func setVisionFallbackMode() {
        lock.withLock {
            useVisionFallback = true
            trackingState = FaceTrackingState()
            hasSmoothedVisionTransform = false
        }
    }

    func setFrameColor(_ color: GlassesFrameColor) {
        lock.withLock {
            guard frameColor != color else { return }
            frameColor = color
            swapGlassesModel(to: color, locked: true)
        }
    }

    func setLensTransparency(_ value: Float) {
        lock.withLock {
            lensTransparency = value
            applyLensTransparency()
        }
    }

    func setFrameBrightness(_ value: Float) {
        lock.withLock {
            frameBrightness = value
            rebuildGlassesModels()
            swapGlassesModel(to: frameColor, locked: true)
        }
    }

    func updateTrackingState(_ state: FaceTrackingState) {
        lock.withLock {
            trackingState = state
            useVisionFallback = false
        }
    }

    func resetTracking() {
        lock.withLock {
            trackingState = FaceTrackingState()
            hasSmoothedVisionTransform = false
        }
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let snapshot = lock.withLock {
            (
                isEnabled: isEnabled,
                useVisionFallback: useVisionFallback,
                trackingState: trackingState
            )
        }
        guard snapshot.isEnabled else { return pixelBuffer }

        var tracking = snapshot.trackingState
        if snapshot.useVisionFallback {
            guard processWithVision(pixelBuffer, tracking: &tracking) else { return pixelBuffer }
        } else {
            guard tracking.isTracking else { return pixelBuffer }
        }

        return renderGlassesOntoBuffer(pixelBuffer, tracking: tracking, useVisionFallback: snapshot.useVisionFallback)
            ?? pixelBuffer
    }

    // MARK: - Vision

    private func processWithVision(_ pixelBuffer: CVPixelBuffer, tracking: inout FaceTrackingState) -> Bool {
        let request = VNDetectFaceLandmarksRequest()
        try? visionSequenceHandler.perform([request], on: pixelBuffer)

        guard let observation = request.results?.first as? VNFaceObservation,
              let landmarks = observation.landmarks else {
            lock.withLock {
                trackingState.isTracking = false
                hasSmoothedVisionTransform = false
            }
            return false
        }

        tracking.isTracking = true

        let bbox = observation.boundingBox
        let leftEyeCenter = eyeCenter(from: landmarks.leftEye, in: bbox)
        let rightEyeCenter = eyeCenter(from: landmarks.rightEye, in: bbox)

        let centerX: CGFloat
        let centerY: CGFloat
        let eyeDistance: CGFloat
        if let leftEyeCenter, let rightEyeCenter {
            centerX = (leftEyeCenter.x + rightEyeCenter.x) * 0.5
            centerY = (leftEyeCenter.y + rightEyeCenter.y) * 0.5
            eyeDistance = hypot(rightEyeCenter.x - leftEyeCenter.x, rightEyeCenter.y - leftEyeCenter.y)
        } else {
            centerX = bbox.midX
            centerY = bbox.midY
            eyeDistance = bbox.width * 0.38
        }

        // Поднимаем оправу в район глаз и масштабируем от межзрачкового расстояния.
        let glassesCenterY = min(max(centerY + bbox.height * 0.06, 0), 1)
        let normalizedScale = max(0.08, min(0.55, eyeDistance * 2.7))

        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(
            Float(centerX - 0.5) * 2,
            Float(glassesCenterY - 0.5) * 2,
            -0.3,
            1
        )
        let scale = Float(normalizedScale)
        transform.columns.0.x = scale
        transform.columns.1.y = scale
        transform.columns.2.z = scale

        let smoothedTransform: simd_float4x4 = lock.withLock {
            if !hasSmoothedVisionTransform {
                smoothedVisionTransform = transform
                hasSmoothedVisionTransform = true
            } else {
                // Сглаживание, чтобы очки не дёргались на каждом кадре Vision.
                smoothedVisionTransform = interpolateTransform(
                    from: smoothedVisionTransform,
                    to: transform,
                    alpha: 0.22
                )
            }
            return smoothedVisionTransform
        }

        tracking.headTransform = smoothedTransform

        if let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye {
            tracking.leftEyeTransform = eyeTransform(from: leftEye, in: bbox)
            tracking.rightEyeTransform = eyeTransform(from: rightEye, in: bbox)
        }

        lock.withLock {
            trackingState = tracking
            glassesNode?.simdTransform = smoothedTransform
        }
        return true
    }

    private func eyeCenter(from region: VNFaceLandmarkRegion2D?, in bbox: CGRect) -> CGPoint? {
        guard let region else { return nil }
        let points = region.normalizedPoints
        guard !points.isEmpty else { return nil }

        let center = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + CGFloat(point.x), y: partial.y + CGFloat(point.y))
        }
        let avg = CGPoint(x: center.x / CGFloat(points.count), y: center.y / CGFloat(points.count))
        return CGPoint(
            x: bbox.origin.x + avg.x * bbox.width,
            y: bbox.origin.y + avg.y * bbox.height
        )
    }

    private func interpolateTransform(from a: simd_float4x4, to b: simd_float4x4, alpha: Float) -> simd_float4x4 {
        var out = matrix_identity_float4x4
        out.columns.0 = simd_mix(a.columns.0, b.columns.0, SIMD4<Float>(repeating: alpha))
        out.columns.1 = simd_mix(a.columns.1, b.columns.1, SIMD4<Float>(repeating: alpha))
        out.columns.2 = simd_mix(a.columns.2, b.columns.2, SIMD4<Float>(repeating: alpha))
        out.columns.3 = simd_mix(a.columns.3, b.columns.3, SIMD4<Float>(repeating: alpha))
        out.columns.3.w = 1
        return out
    }

    private func eyeTransform(from region: VNFaceLandmarkRegion2D, in bbox: CGRect) -> simd_float4x4 {
        let points = region.normalizedPoints
        guard !points.isEmpty else { return matrix_identity_float4x4 }

        let center = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let avg = CGPoint(x: center.x / CGFloat(points.count), y: center.y / CGFloat(points.count))

        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(Float(avg.x), Float(avg.y), 0, 1)
        return t
    }

    // MARK: - Rendering

    private func renderGlassesOntoBuffer(
        _ pixelBuffer: CVPixelBuffer,
        tracking: FaceTrackingState,
        useVisionFallback: Bool
    ) -> CVPixelBuffer? {
        let hasGlasses = lock.withLock { () -> Bool in
            guard let glassesNode else { return false }
            if !useVisionFallback {
                glassesNode.simdTransform = tracking.headTransform
            }
            return true
        }
        guard hasGlasses else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let image = sceneRenderer.snapshot(
            atTime: CACurrentMediaTime(),
            with: CGSize(width: width, height: height),
            antialiasingMode: .multisampling4X
        )

        return compositeOverlay(image.cgImage, onto: pixelBuffer)
    }

    private func compositeOverlay(_ overlay: CGImage?, onto buffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let overlay else { return buffer }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return buffer }

        context.draw(overlay, in: CGRect(
            x: 0, y: 0,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer)
        ))

        return buffer
    }

    // MARK: - Scene

    private func rebuildGlassesModels() {
        redGlassesNode = GlassesOverlayService.buildMonokolMK295(color: .red, brightness: frameBrightness)
        blueGlassesNode = GlassesOverlayService.buildMonokolMK295(color: .blue, brightness: frameBrightness)
    }

    private func swapGlassesModel(to color: GlassesFrameColor, locked: Bool) {
        let apply = {
            self.glassesNode?.removeFromParentNode()

            let node: SCNNode?
            switch color {
            case .red: node = self.redGlassesNode?.clone()
            case .blue: node = self.blueGlassesNode?.clone()
            }

            guard let node else { return }
            node.name = "glasses"
            self.glassesNode = node
            self.scene.rootNode.addChildNode(node)
            self.applyLensTransparency()
        }

        if locked {
            apply()
        } else {
            lock.withLock { apply() }
        }
    }

    private func applyLensTransparency() {
        glassesNode?.childNode(withName: "leftLens", recursively: true)?
            .geometry?.firstMaterial?.transparent.contents = NSNumber(value: lensTransparency)
        glassesNode?.childNode(withName: "rightLens", recursively: true)?
            .geometry?.firstMaterial?.transparent.contents = NSNumber(value: lensTransparency)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
